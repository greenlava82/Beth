import 'tempo_detector.dart';

/// Decides when the detected tempo is shown as a BPM rather than
/// "Listening…", with hysteresis and a hold so the readout doesn't flicker.
///
/// The BPM appears once confidence reaches [showAbove]. It stays up while
/// confidence is at least `showAbove - hysteresis`. Below that it keeps
/// showing the last good reading for [holdSeconds] more before going away,
/// so a short gap in the music (a break, a fill) doesn't lose the tempo.
class TempoDisplayGate {
  TempoDisplayGate({
    this.showAbove = defaultShowAbove,
    this.hysteresis = defaultHysteresis,
    this.holdSeconds = defaultHoldSeconds,
  });

  static const double defaultShowAbove = 0.2;
  static const double defaultHysteresis = 0.1;
  static const double defaultHoldSeconds = 3;

  /// Confidence needed to start showing a BPM.
  double showAbove;

  /// How far confidence may fall below [showAbove] before the reading
  /// counts as weak.
  double hysteresis;

  /// How long a weak (or missing) reading keeps the last good BPM up.
  double holdSeconds;

  /// Confidence below which a showing reading counts as weak.
  double get hideBelow => (showAbove - hysteresis).clamp(0.0, 1.0);

  bool _showing = false;
  double _bpm = 0;
  double _confidence = 0;
  DateTime? _lastGood;

  /// The BPM to show; 0 means show "Listening…".
  double get bpm => _showing ? _bpm : 0;

  /// Confidence of the reading being shown (0 when none).
  double get confidence => _showing ? _confidence : 0;

  void reset() {
    _showing = false;
    _bpm = 0;
    _confidence = 0;
    _lastGood = null;
  }

  /// Feed the latest estimate (null = silence). Returns [bpm].
  double update(TempoEstimate? estimate, DateTime now) {
    final threshold = _showing ? hideBelow : showAbove;
    // A reading counts at the threshold itself, so hideBelow of 0 keeps any
    // estimate alive.
    if (estimate != null &&
        estimate.confidence > 0 &&
        estimate.confidence >= threshold) {
      _showing = true;
      _bpm = estimate.bpm;
      _confidence = estimate.confidence;
      _lastGood = now;
    } else {
      tick(now);
    }
    return bpm;
  }

  /// Expire a held reading with no new estimate. Returns [bpm].
  double tick(DateTime now) {
    final last = _lastGood;
    if (_showing && last != null) {
      if (now.difference(last).inMilliseconds >= holdSeconds * 1000) reset();
    }
    return bpm;
  }
}
