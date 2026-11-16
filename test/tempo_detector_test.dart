import 'dart:math' as math;
import 'dart:typed_data';

import 'package:scbeatwiz/tempo_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const sr = 44100;

/// Tiny additive synth for test signals.
class Synth {
  Synth(double seconds, {int seed = 1})
      : buf = Float64List((seconds * sr).round()),
        rnd = math.Random(seed);
  final Float64List buf;
  final math.Random rnd;

  double get seconds => buf.length / sr;

  void _add(double t0, double dur, double Function(double t) f) {
    final s0 = (t0 * sr).round();
    final n = (dur * sr).round();
    for (var i = 0; i < n; i++) {
      final idx = s0 + i;
      if (idx < 0 || idx >= buf.length) continue;
      buf[idx] += f(i / sr);
    }
  }

  void kick(double t, [double amp = 0.8]) => _add(t, 0.3, (x) {
        final f = 50 + 100 * math.exp(-x * 30);
        return amp * math.sin(2 * math.pi * f * x) * math.exp(-x * 12);
      });

  void snare(double t, [double amp = 0.5]) {
    double prev = 0;
    _add(t, 0.2, (x) {
      final n = rnd.nextDouble() * 2 - 1;
      final hp = n - prev;
      prev = n;
      return amp *
          (0.6 * hp + 0.4 * math.sin(2 * math.pi * 190 * x)) *
          math.exp(-x * 25);
    });
  }

  void hat(double t, [double amp = 0.15]) {
    double prev = 0;
    _add(t, 0.05, (x) {
      final n = rnd.nextDouble() * 2 - 1;
      final hp = n - prev;
      prev = n;
      return amp * hp * math.exp(-x * 80);
    });
  }

  void snap(double t, [double amp = 0.5]) {
    double prev = 0;
    _add(t, 0.04, (x) {
      final n = rnd.nextDouble() * 2 - 1;
      final hp = n - prev;
      prev = n;
      return amp * hp * math.exp(-x * 120);
    });
  }

  /// Piano-ish note: harmonics with decaying envelope.
  void note(double t, double freq,
      {double amp = 0.2, double decay = 2.5, double dur = 1.5, int harm = 6}) {
    _add(t, dur, (x) {
      double s = 0;
      for (var h = 1; h <= harm; h++) {
        s += math.sin(2 * math.pi * freq * h * x) / h * math.exp(-x * decay * h * 0.6);
      }
      final atk = math.min(1.0, x / 0.004);
      return amp * atk * s;
    });
  }

  /// Guitar strum: 6 strings staggered by a few ms.
  void strum(double t, List<double> freqs, {double amp = 0.12, bool down = true}) {
    for (var i = 0; i < freqs.length; i++) {
      final idx = down ? i : freqs.length - 1 - i;
      note(t + i * 0.008, freqs[idx], amp: amp, decay: 3, dur: 1.0, harm: 8);
    }
  }

  void noise(double amp) {
    for (var i = 0; i < buf.length; i++) {
      buf[i] += amp * (rnd.nextDouble() * 2 - 1);
    }
  }

  /// Human timing jitter, in seconds (Gaussian-ish).
  double jit(double sd) =>
      sd * (rnd.nextDouble() + rnd.nextDouble() + rnd.nextDouble() - 1.5) * 1.4;

  Uint8List toPcm16() {
    var peak = 1e-9;
    for (final v in buf) {
      peak = math.max(peak, v.abs());
    }
    final g = peak > 0.95 ? 0.95 / peak : 1.0;
    final out = Uint8List(buf.length * 2);
    final bd = ByteData.view(out.buffer);
    for (var i = 0; i < buf.length; i++) {
      bd.setInt16(i * 2, (buf[i] * g * 32767).round().clamp(-32768, 32767),
          Endian.little);
    }
    return out;
  }
}

double midi(int m) => 440 * math.pow(2, (m - 69) / 12).toDouble();

/// Runs the detector over [s], feeding odd-sized chunks like a real mic
/// stream, and returns the final estimate.
TempoEstimate? run(Synth s,
    {double? expected,
    double priorWidth = 0.9,
    double rangeMin = 90,
    double rangeMax = 160,
    List<TempoEstimate>? log}) {
  final d = TempoDetector(
      sampleRate: sr,
      expectedBpm: expected,
      priorOctaveWidth: priorWidth,
      preferredMinBpm: rangeMin,
      preferredMaxBpm: rangeMax);
  final pcm = s.toPcm16();
  const chunk = 1777; // deliberately odd
  for (var i = 0; i < pcm.length; i += chunk) {
    final e = d.addPcm16(
        Uint8List.sublistView(pcm, i, math.min(pcm.length, i + chunk)));
    if (e != null) log?.add(e);
  }
  return d.current;
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

Synth rock(double bpm) {
  final s = Synth(15, seed: 2);
  final b = 60 / bpm;
  for (var i = 0; i * b < s.seconds; i++) {
    final t = i * b;
    if (i % 2 == 0) {
      s.kick(t + s.jit(0.005));
    } else {
      s.snare(t + s.jit(0.005));
    }
    s.hat(t);
    s.hat(t + b / 2, 0.08);
  }
  s.noise(0.003);
  return s;
}

Synth house(double bpm) {
  final s = Synth(15, seed: 3);
  final b = 60 / bpm;
  for (var i = 0; i * b < s.seconds; i++) {
    s.kick(i * b);
    s.hat(i * b + b / 2, 0.2);
    if (i % 2 == 1) s.snap(i * b, 0.3);
  }
  return s;
}

Synth snapsEveryBeat(double bpm) {
  final s = Synth(15, seed: 4);
  final b = 60 / bpm;
  for (var i = 0; i * b < s.seconds; i++) {
    s.snap(i * b + s.jit(0.012), 0.4 + 0.2 * s.rnd.nextDouble());
  }
  s.noise(0.01);
  return s;
}

Synth snapsBackbeat(double bpm) {
  // Finger snaps on 2 and 4 only, with a quiet vocal-ish hum.
  final s = Synth(15, seed: 5);
  final b = 60 / bpm;
  for (var i = 1; i * b < s.seconds; i += 2) {
    s.snap(i * b + s.jit(0.01), 0.5);
  }
  s.noise(0.005);
  return s;
}

Synth pianoChords(double bpm) {
  final s = Synth(15, seed: 6);
  final b = 60 / bpm;
  final prog = [
    [60, 64, 67], [57, 60, 64], [65, 69, 72], [67, 71, 74],
  ];
  for (var i = 0; i * b < s.seconds; i++) {
    final chord = prog[(i ~/ 4) % prog.length];
    final t = i * b + s.jit(0.015);
    final vel = i % 4 == 0 ? 0.25 : 0.15;
    for (final m in chord) {
      s.note(t, midi(m), amp: vel, decay: 1.2, dur: 2.0);
    }
    if (i % 4 == 0) s.note(t, midi(chord[0] - 24), amp: 0.25, decay: 0.8, dur: 3);
  }
  return s;
}

Synth pianoArpeggio(double bpm) {
  // Eighth-note arpeggios, sustained — classic octave-error trap.
  final s = Synth(15, seed: 7);
  final b = 60 / bpm;
  final pat = [48, 55, 60, 64, 67, 64, 60, 55];
  for (var i = 0; i * b / 2 < s.seconds; i++) {
    final t = i * b / 2 + s.jit(0.01);
    final accent = i % 2 == 0 ? 0.2 : 0.12;
    s.note(t, midi(pat[i % pat.length] + ((i ~/ 16) % 2) * 5),
        amp: accent, decay: 0.9, dur: 1.5);
  }
  return s;
}

Synth guitarStrums(double bpm) {
  final s = Synth(15, seed: 8);
  final b = 60 / bpm;
  final g = [40, 47, 52, 55, 59, 64].map(midi).toList(); // E major-ish
  final c = [48, 52, 55, 60, 64].map(midi).toList();
  for (var i = 0; i * b / 2 < s.seconds; i++) {
    final chord = (i ~/ 8) % 2 == 0 ? g : c;
    final down = i % 2 == 0;
    s.strum(i * b / 2 + s.jit(0.008), chord, amp: down ? 0.10 : 0.05, down: down);
  }
  return s;
}

Synth legatoBass(double bpm) {
  // Continuous bass line: pitch changes each beat, tiny amplitude dip only.
  final s = Synth(15, seed: 9);
  final b = 60 / bpm;
  final line = [40, 43, 45, 47, 45, 43, 38, 40];
  final n = s.buf.length;
  double phase = 0;
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final beat = (t / b).floor();
    final f = midi(line[beat % line.length]) / 2; // ~41-62 Hz
    final pos = (t - beat * b) / b;
    final env = 0.85 + 0.15 * math.exp(-pos * 8);
    phase += 2 * math.pi * f / sr;
    s.buf[i] = 0.4 * env * (math.sin(phase) + 0.5 * math.sin(2 * phase) + 0.25 * math.sin(3 * phase));
  }
  return s;
}

Synth hiphopSwing(double bpm) {
  final s = Synth(15, seed: 10);
  final b = 60 / bpm;
  for (var bar = 0; bar * 4 * b < s.seconds; bar++) {
    final t0 = bar * 4 * b;
    s.kick(t0);
    s.kick(t0 + 1.5 * b + 0.06 * b);
    s.kick(t0 + 2.5 * b);
    s.snare(t0 + b);
    s.snare(t0 + 3 * b);
    for (var e = 0; e < 8; e++) {
      final sw = e % 2 == 1 ? 0.16 * b : 0.0; // swung eighths
      s.hat(t0 + e * b / 2 + sw, e % 2 == 0 ? 0.12 : 0.07);
    }
  }
  return s;
}

Synth waltz(double bpm) {
  final s = Synth(15, seed: 11);
  final b = 60 / bpm;
  for (var i = 0; i * b < s.seconds; i++) {
    if (i % 3 == 0) {
      s.note(i * b, midi(43), amp: 0.3, decay: 1.5);
    } else {
      for (final m in [59, 62, 67]) {
        s.note(i * b, midi(m), amp: 0.12, decay: 3, dur: 0.5);
      }
    }
  }
  return s;
}

Synth tempoChange(double a, double b2) {
  final s = Synth(20, seed: 12);
  var t = 0.0;
  var i = 0;
  while (t < s.seconds) {
    final bpm = t < 8 ? a : b2;
    if (i % 2 == 0) {
      s.kick(t);
    } else {
      s.snare(t);
    }
    s.hat(t);
    t += 60 / bpm;
    i++;
  }
  return s;
}

void main() {
  bool ok(TempoEstimate? e, double bpm, {double tol = 0.02}) =>
      e != null && (e.bpm - bpm).abs() / bpm <= tol;

  final cases = <String, (Synth Function(), double)>{
    'rock drums 120': (() => rock(120), 120),
    'house 128': (() => house(128), 128),
    'snaps every beat 104': (() => snapsEveryBeat(104), 104),
    'snaps on 2&4 at 92': (() => snapsBackbeat(92), 92),
    'piano chords 72': (() => pianoChords(72), 72),
    'piano 8th arpeggio 100': (() => pianoArpeggio(100), 100),
    'guitar strums 8ths 140': (() => guitarStrums(140), 140),
    'legato bass 85': (() => legatoBass(85), 85),
    'hip-hop swing 90': (() => hiphopSwing(90), 90),
    'waltz 3/4 150': (() => waltz(150), 150),
  };

  group('with song target as expected tempo', () {
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (make, bpm) = entry.value;
        final e = run(make(), expected: bpm, priorWidth: 0.6);
        // ignore: avoid_print
        print('${entry.key.padRight(26)} -> $e');
        expect(ok(e, bpm), isTrue, reason: '$e');
      });
    }
  });

  group('no hint, default preferred range 90-160', () {
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (make, bpm) = entry.value;
        final e = run(make());
        // ignore: avoid_print
        print('${entry.key.padRight(26)} -> $e');
        // Without a hint, half/double tempo is a legitimate reading...
        final octaveOk = ok(e, bpm) || ok(e, bpm * 2) || ok(e, bpm / 2);
        expect(octaveOk, isTrue, reason: '$e');
        // ...but if an octave of the true tempo falls in range, pick it.
        final inRange = [bpm / 2, bpm, bpm * 2].where((b) => b >= 90 && b <= 160);
        if (inRange.isNotEmpty) {
          expect(e!.bpm, inInclusiveRange(88, 163), reason: '$e');
        }
      });
    }
  });

  test('custom preferred range changes octave choice', () {
    final low = run(pianoChords(72), rangeMin: 60, rangeMax: 100);
    final high = run(pianoChords(72), rangeMin: 120, rangeMax: 180);
    // ignore: avoid_print
    print('piano 72 in 60-100 -> $low, in 120-180 -> $high');
    expect(ok(low, 72), isTrue, reason: '$low');
    expect(ok(high, 144), isTrue, reason: '$high');
  });

  test('range can be changed live', () {
    final d = TempoDetector(sampleRate: sr);
    d.setPreferredRange(160, 60); // swapped handles are normalised
    expect(d.preferredMinBpm, 60);
    expect(d.preferredMaxBpm, 160);
  });

  // Free-running mode in the app: no song target, so lean toward the most
  // common tempos (prefer 80-160, gentle pull toward 120).
  group('free-running (common tempos, no target)', () {
    for (final entry in cases.entries) {
      test(entry.key, () {
        final (make, bpm) = entry.value;
        final e = run(make(),
            expected: 120, priorWidth: 0.6, rangeMin: 80, rangeMax: 160);
        // ignore: avoid_print
        print('${entry.key.padRight(26)} -> $e');
        final octaveOk = ok(e, bpm) || ok(e, bpm * 2) || ok(e, bpm / 2);
        expect(octaveOk, isTrue, reason: '$e');
        final inRange =
            [bpm / 2, bpm, bpm * 2].where((b) => b >= 80 && b <= 160);
        if (inRange.isNotEmpty) {
          expect(e!.bpm, inInclusiveRange(78, 163), reason: '$e');
        }
      });
    }
  });

  test('tempo change 100 -> 130 is followed', () {
    final log = <TempoEstimate>[];
    final e = run(tempoChange(100, 130), log: log);
    // ignore: avoid_print
    print('tempo change: ${log.map((e) => e.bpm.round()).join(' ')}');
    expect(ok(e, 130), isTrue, reason: '$e');
  });

  test('silence gives no estimate', () {
    final s = Synth(10);
    expect(run(s), isNull);
  });

  test('noise gives low confidence', () {
    final s = Synth(10)..noise(0.2);
    final e = run(s);
    // ignore: avoid_print
    print('white noise -> $e');
    expect(e == null || e.confidence < 0.1, isTrue, reason: '$e');
  });
}
