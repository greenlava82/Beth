import 'dart:math' as math;
import 'dart:typed_data';

/// A tempo reading produced by [TempoDetector].
class TempoEstimate {
  /// Detected tempo in beats per minute.
  final double bpm;

  /// 0..1 — how strongly periodic the recent audio is at [bpm].
  /// Roughly: < 0.1 is a guess, > 0.3 is a solid groove.
  final double confidence;

  const TempoEstimate(this.bpm, this.confidence);

  @override
  String toString() =>
      'TempoEstimate(${bpm.toStringAsFixed(1)} BPM, conf ${confidence.toStringAsFixed(2)})';
}

/// Real-time, instrument-agnostic tempo detector.
///
/// Pipeline:
///  1. **Onset strength** — short-time FFT (2048 window, 10 ms hop), mapped to
///     log-spaced bands (~6 per octave, 30 Hz–16 kHz), log-compressed. The
///     onset signal is the positive change per band vs. 20 ms earlier, with a
///     max filter across neighbouring bands (SuperFlux-style) so vibrato and
///     sustained notes don't fire. Because it tracks *new spectral content*
///     rather than loudness, it picks up drums and snaps as well as piano,
///     guitar and bass note changes.
///  2. **Periodicity** — autocorrelation of the last [windowSeconds] of onset
///     strength, scored with a harmonic comb (lag, 2·lag, 3·lag, 4·lag) so a
///     real beat — which repeats at every multiple — beats coincidental peaks.
///  3. **Octave choice** — a soft preference for [preferredMinBpm]..
///     [preferredMaxBpm] (default 90–160), optionally combined with a pull
///     toward [expectedBpm], resolves the inherent 2x ambiguity
///     (eighth-notes vs. quarter-notes).
///  4. **Tracking** — the per-tempo scores are smoothed over time with a small
///     Gaussian blur, so the reading is stable yet follows tempo changes.
class TempoDetector {
  TempoDetector({
    this.sampleRate = 44100,
    this.minBpm = 40,
    this.maxBpm = 220,
    double? expectedBpm,
    double preferredMinBpm = 90,
    double preferredMaxBpm = 160,
    this.preferredFalloffOctaves = 0.2,
    this.windowSeconds = 8,
    this.updateIntervalSeconds = 0.5,
    this.priorOctaveWidth = 0.9,
  })  : _expectedBpm = expectedBpm,
        _preferredMin = preferredMinBpm,
        _preferredMax = preferredMaxBpm {
    _hop = (sampleRate / 100).round();
    frameRate = sampleRate / _hop;
    _initFft();
    _initBands();
    _odf = Float64List((windowSeconds * frameRate).ceil());
    _rms = Float64List(_odf.length);
    final gridSize = ((maxBpm - minBpm) / _gridStep).round() + 1;
    _grid = Float64List.fromList(
        List.generate(gridSize, (i) => minBpm + i * _gridStep));
    _state = Float64List(gridSize);
    _rebuildPrior();
  }

  final int sampleRate;
  final double minBpm;
  final double maxBpm;
  final double windowSeconds;
  final double updateIntervalSeconds;

  /// Tempos in [preferredMinBpm]..[preferredMaxBpm] get full weight; outside
  /// it the weight falls off smoothly (1 sigma = [preferredFalloffOctaves]).
  /// This is a soft preference used to pick between half/double tempo — a
  /// clear 70 BPM groove can still read 70, but an ambiguous 70/140 reads 140.
  double get preferredMinBpm => _preferredMin;
  double get preferredMaxBpm => _preferredMax;
  final double preferredFalloffOctaves;
  double _preferredMin;
  double _preferredMax;

  /// Change the preferred tempo range (e.g. from a UI slider).
  void setPreferredRange(double minBpm, double maxBpm) {
    if (maxBpm < minBpm) {
      final t = minBpm;
      minBpm = maxBpm;
      maxBpm = t;
    }
    if (minBpm == _preferredMin && maxBpm == _preferredMax) return;
    _preferredMin = minBpm;
    _preferredMax = maxBpm;
    _rebuildPrior();
  }

  /// Width (in octaves, 1 sigma) of the pull toward [expectedBpm]. Smaller =
  /// stronger pull.
  final double priorOctaveWidth;

  /// Onset frames per second (~100).
  late final double frameRate;

  double? _expectedBpm;

  /// Optional tempo hint (e.g. the song's target BPM). Combined with the
  /// preferred range when choosing between octaves (60 vs 120). Null = use
  /// the preferred range alone.
  double? get expectedBpm => _expectedBpm;
  set expectedBpm(double? v) {
    if (v != null && v <= 0) v = null;
    if (v == _expectedBpm) return;
    _expectedBpm = v;
    _rebuildPrior();
  }

  /// Most recent estimate, or null when silent / not enough audio yet.
  TempoEstimate? get current => _current;

  static const int _fftSize = 2048;
  static const double _gridStep = 0.25;
  static const double _silenceRms = 0.001; // ~ -60 dBFS
  static const double _minSecondsForEstimate = 3.0;
  static const double _stateDecay = 0.75; // per update (~0.5 s)
  // Weight of a half/double-tempo relative's strength when scoring a
  // candidate; < 1 keeps a slight preference for the directly observed pulse.
  static const double _octaveFold = 0.8;

  late final int _hop;

  // --- framing ---
  final Float64List _pending = Float64List(_fftSize * 4);
  int _pendingCount = 0;
  int? _carryByte; // odd byte from a previous PCM chunk

  // --- FFT ---
  late final Float64List _window;
  late final Float64List _cos;
  late final Float64List _sin;
  late final Int32List _bitRev;
  final Float64List _re = Float64List(_fftSize);
  final Float64List _im = Float64List(_fftSize);

  // --- bands ---
  late final Int32List _bandLo;
  late final Int32List _bandHi;
  late Float64List _bandsPrev1;
  late Float64List _bandsPrev2;
  bool _haveFrames = false;

  // --- onset ring buffer ---
  late final Float64List _odf;
  late final Float64List _rms;
  int _odfWrite = 0;
  int _odfCount = 0;
  int _framesSinceUpdate = 0;

  // --- tempo scoring ---
  late final Float64List _grid;
  late Float64List _prior;
  late Float64List _state;
  TempoEstimate? _current;

  /// Clear all history (e.g. when the mic restarts or the song changes).
  void reset() {
    _pendingCount = 0;
    _carryByte = null;
    _haveFrames = false;
    _odfWrite = 0;
    _odfCount = 0;
    _framesSinceUpdate = 0;
    _state.fillRange(0, _state.length, 0);
    _current = null;
  }

  /// Feed little-endian 16-bit mono PCM bytes. Chunks may be any length.
  /// Returns a new estimate whenever one is computed (about every
  /// [updateIntervalSeconds]), otherwise null.
  TempoEstimate? addPcm16(Uint8List bytes) {
    TempoEstimate? result;
    var i = 0;
    if (_carryByte != null && bytes.isNotEmpty) {
      final v = (_carryByte! | (bytes[0] << 8)).toSigned(16);
      result = _pushSample(v / 32768.0) ?? result;
      _carryByte = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      final v = (bytes[i] | (bytes[i + 1] << 8)).toSigned(16);
      result = _pushSample(v / 32768.0) ?? result;
    }
    if (i < bytes.length) _carryByte = bytes[i];
    return result;
  }

  /// Feed float samples in -1..1.
  TempoEstimate? addSamples(List<double> samples) {
    TempoEstimate? result;
    for (final s in samples) {
      result = _pushSample(s) ?? result;
    }
    return result;
  }

  TempoEstimate? _pushSample(double s) {
    _pending[_pendingCount++] = s;
    if (_pendingCount < _fftSize) return null;
    final r = _processFrame();
    // slide by hop
    _pending.setRange(0, _pendingCount - _hop, _pending, _hop);
    _pendingCount -= _hop;
    return r;
  }

  // ==========================================================================
  // Onset detection
  // ==========================================================================

  TempoEstimate? _processFrame() {
    double energy = 0;
    for (var n = 0; n < _fftSize; n++) {
      final s = _pending[n];
      energy += s * s;
      _re[n] = s * _window[n];
      _im[n] = 0;
    }
    final rms = math.sqrt(energy / _fftSize);
    _fft();

    final nb = _bandLo.length;
    final bands = Float64List(nb);
    const norm = 2.0 / (_fftSize / 2); // full-scale sine -> ~1
    for (var b = 0; b < nb; b++) {
      double sum = 0;
      for (var k = _bandLo[b]; k < _bandHi[b]; k++) {
        sum += math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
      }
      final mag = sum * norm / (_bandHi[b] - _bandLo[b]);
      bands[b] = math.log(1 + 1000 * mag);
    }

    double flux = 0;
    if (_haveFrames) {
      final ref = _bandsPrev2;
      for (var b = 0; b < nb; b++) {
        var m = ref[b];
        if (b > 0 && ref[b - 1] > m) m = ref[b - 1];
        if (b + 1 < nb && ref[b + 1] > m) m = ref[b + 1];
        final d = bands[b] - m;
        if (d > 0) flux += d;
      }
      _bandsPrev2 = _bandsPrev1;
      _bandsPrev1 = bands;
    } else {
      _bandsPrev1 = bands;
      _bandsPrev2 = bands;
      _haveFrames = true;
    }

    _odf[_odfWrite] = flux;
    _rms[_odfWrite] = rms;
    _odfWrite = (_odfWrite + 1) % _odf.length;
    if (_odfCount < _odf.length) _odfCount++;

    if (++_framesSinceUpdate >= updateIntervalSeconds * frameRate) {
      _framesSinceUpdate = 0;
      return _analyze();
    }
    return null;
  }

  // ==========================================================================
  // Tempo estimation
  // ==========================================================================

  TempoEstimate? _analyze() {
    final n = _odfCount;
    if (n < _minSecondsForEstimate * frameRate) return null;

    // Linearise ring buffer (oldest first).
    final x = Float64List(n);
    final start = (_odfWrite - n + _odf.length) % _odf.length;
    double rmsSum = 0;
    final recent = math.min(n, (2 * frameRate).round());
    for (var i = 0; i < n; i++) {
      final idx = (start + i) % _odf.length;
      x[i] = _odf[idx];
      if (i >= n - recent) rmsSum += _rms[idx];
    }

    if (rmsSum / recent < _silenceRms) {
      _decayState(0.5);
      _current = null;
      return null;
    }

    // Remove slow trend (local mean over ±100 ms), half-wave rectify,
    // then make zero-mean.
    const r = 10;
    final y = Float64List(n);
    double run = 0;
    var lo = 0, hi = -1;
    double mean = 0;
    for (var i = 0; i < n; i++) {
      while (hi < math.min(n - 1, i + r)) {
        run += x[++hi];
      }
      while (lo < i - r) {
        run -= x[lo++];
      }
      final v = x[i] - run / (hi - lo + 1);
      y[i] = v > 0 ? v : 0;
      mean += y[i];
    }
    mean /= n;
    for (var i = 0; i < n; i++) {
      y[i] -= mean;
    }

    // Autocorrelation, unbiased, normalised to acf[0] = 1.
    final maxLag = math.min(n - (frameRate * 1.5).round(),
        (4 * 60 * frameRate / minBpm).ceil() + 2);
    if (maxLag < 60 * frameRate / minBpm) return null;
    final acf = Float64List(maxLag + 1);
    for (var lag = 0; lag <= maxLag; lag++) {
      double s = 0;
      for (var i = 0; i + lag < n; i++) {
        s += y[i] * y[i + lag];
      }
      acf[lag] = s / (n - lag);
    }
    if (acf[0] <= 1e-12) {
      _decayState(0.5);
      _current = null;
      return null;
    }
    final a0 = acf[0];
    for (var lag = 0; lag <= maxLag; lag++) {
      acf[lag] /= a0;
    }

    double acfAt(double lag) {
      final i = lag.floor();
      if (i + 1 > maxLag) return double.nan;
      final f = lag - i;
      return acf[i] * (1 - f) + acf[i + 1] * f;
    }

    // Harmonic comb score for one tempo candidate.
    double combAt(double bpm) {
      final lag = 60 * frameRate / bpm;
      double s = 0, w = 0;
      for (var k = 1; k <= 4; k++) {
        final v = acfAt(lag * k);
        if (v.isNaN) break;
        // Use the local max within ±1 frame so slight timing drift
        // (human players) still lines up.
        final v2 = math.max(v, math.max(acfAt(lag * k - 1), acfAt(lag * k + 1)));
        final wk = 1.0 / k;
        s += wk * (v2.isNaN ? v : v2);
        w += wk;
      }
      final score = w > 0 ? s / w : 0.0;
      return score > 0 ? score : 0.0;
    }

    // Score each candidate by the strength of its whole metrical family
    // (half, same, double tempo), so the octave is chosen by the prior —
    // i.e. the preferred range and the song hint — rather than by whichever
    // pulse level happens to be loudest.
    final g = _grid.length;
    final raw = Float64List(g);
    double rawMax = 0;
    for (var j = 0; j < g; j++) {
      final b = _grid[j];
      // Credit for being double a slower pulse — unless that slower pulse
      // is really a bar of three: then there's also a strong pulse at 1.5x
      // this candidate (e.g. a 150 BPM waltz has bars at 50, and 100 would
      // otherwise borrow their strength).
      final half = combAt(b / 2);
      final halfFold = combAt(b * 1.5) > 0.6 * half ? 0.0 : half;
      raw[j] = math.max(combAt(b),
          _octaveFold * math.max(halfFold, combAt(b * 2)));
      if (raw[j] > rawMax) rawMax = raw[j];
    }

    // Combine with prior, accumulate into the smoothed state.
    _decayState(_stateDecay);
    if (rawMax > 0) {
      for (var j = 0; j < g; j++) {
        _state[j] += (1 - _stateDecay) * raw[j] * _prior[j];
      }
    }

    var best = 0;
    for (var j = 1; j < g; j++) {
      if (_state[j] > _state[best]) best = j;
    }
    if (_state[best] <= 0) {
      _current = null;
      return null;
    }

    // Sub-grid refinement with parabolic interpolation.
    double bpm = _grid[best];
    if (best > 0 && best < g - 1) {
      final a = _state[best - 1], b = _state[best], c = _state[best + 1];
      final denom = a - 2 * b + c;
      if (denom < 0) {
        final off = 0.5 * (a - c) / denom;
        bpm += off.clamp(-0.5, 0.5) * _gridStep;
      }
    }

    final confidence = raw[best].clamp(0.0, 1.0);
    _current = TempoEstimate(bpm, confidence);
    return _current;
  }

  /// Decay the state and blur it slightly so the peak can drift with
  /// gradual tempo changes.
  void _decayState(double decay) {
    final g = _state.length;
    final out = Float64List(g);
    const k = [0.06, 0.24, 0.40, 0.24, 0.06]; // ~1 grid-step sigma
    for (var j = 0; j < g; j++) {
      double s = 0, w = 0;
      for (var t = -2; t <= 2; t++) {
        final jj = j + t;
        if (jj < 0 || jj >= g) continue;
        s += k[t + 2] * _state[jj];
        w += k[t + 2];
      }
      out[j] = decay * s / w;
    }
    _state = out;
  }

  void _rebuildPrior() {
    _prior = Float64List(_grid.length);
    double gauss(double octaves, double sigma) =>
        math.exp(-0.5 * (octaves / sigma) * (octaves / sigma));
    double log2(double x) => math.log(x) / math.ln2;
    for (var j = 0; j < _grid.length; j++) {
      final bpm = _grid[j];
      // Flat-topped preferred range, widened to include the hint (±10%) so
      // a song deliberately set outside the range still reads correctly.
      final e = _expectedBpm;
      final lo = e == null ? _preferredMin : math.min(_preferredMin, e * 0.9);
      final hi = e == null ? _preferredMax : math.max(_preferredMax, e * 1.1);
      var p = 1.0;
      if (bpm < lo) {
        p = gauss(log2(lo / bpm), preferredFalloffOctaves);
      } else if (bpm > hi) {
        p = gauss(log2(bpm / hi), preferredFalloffOctaves);
      }
      // Optional pull toward the hint.
      if (e != null) p *= gauss(log2(bpm / e), priorOctaveWidth);
      _prior[j] = p;
    }
  }

  // ==========================================================================
  // Setup helpers
  // ==========================================================================

  void _initFft() {
    _window = Float64List(_fftSize);
    for (var n = 0; n < _fftSize; n++) {
      _window[n] = 0.5 - 0.5 * math.cos(2 * math.pi * n / _fftSize);
    }
    _cos = Float64List(_fftSize ~/ 2);
    _sin = Float64List(_fftSize ~/ 2);
    for (var i = 0; i < _fftSize ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / _fftSize);
      _sin[i] = -math.sin(2 * math.pi * i / _fftSize);
    }
    _bitRev = Int32List(_fftSize);
    final bits = (math.log(_fftSize) / math.ln2).round();
    for (var i = 0; i < _fftSize; i++) {
      var r = 0, v = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      _bitRev[i] = r;
    }
  }

  void _fft() {
    final re = _re, im = _im;
    for (var i = 0; i < _fftSize; i++) {
      final j = _bitRev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= _fftSize; size <<= 1) {
      final half = size >> 1;
      final step = _fftSize ~/ size;
      for (var start = 0; start < _fftSize; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }

  void _initBands() {
    final binHz = sampleRate / _fftSize;
    final top = math.min(16000.0, sampleRate / 2 - binHz);
    final los = <int>[], his = <int>[];
    var prevHi = math.max(1, (30 / binHz).round());
    for (var i = 1;; i++) {
      final f = 30 * math.pow(2, i / 6.0);
      if (f > top) break;
      var hi = (f / binHz).round();
      if (hi <= prevHi) continue; // too narrow at low freq — merge
      los.add(prevHi);
      his.add(hi);
      prevHi = hi;
    }
    _bandLo = Int32List.fromList(los);
    _bandHi = Int32List.fromList(his);
    _bandsPrev1 = Float64List(los.length);
    _bandsPrev2 = Float64List(los.length);
  }
}
