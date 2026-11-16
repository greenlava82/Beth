import 'dart:math' as math;

/// How far the heard tempo is from the song's target.
enum DriftLevel {
  /// Within a couple of percent: on tempo.
  onTempo,

  /// Noticeably off, but not by much.
  drifting,

  /// Well off the target.
  off,
}

/// A drift reading for display.
class TempoDrift {
  const TempoDrift({
    required this.level,
    required this.deltaBpm,
    required this.percent,
    this.octave = 1,
  });

  final DriftLevel level;

  /// Heard minus target (after octave correction), in BPM. Positive = rushing.
  final double deltaBpm;

  /// [deltaBpm] as a percentage of the target.
  final double percent;

  /// 2 if the band is heard at double time, 0.5 at half time, else 1.
  final double octave;

  bool get isRushing => deltaBpm > 0;
  bool get isHalfOrDoubleTime => octave != 1;

  @override
  String toString() =>
      'TempoDrift($level, ${deltaBpm.toStringAsFixed(1)} BPM, '
      '${percent.toStringAsFixed(1)}%, x$octave)';
}

/// Classifies the heard tempo against the target, with hysteresis so the
/// level doesn't flicker when the tempo sits near a threshold.
///
/// Defaults: on tempo within ±2%, drifting up to ±5%, off beyond that. A
/// level is entered past its threshold plus half the [hysteresisPercent]
/// margin and left only once back inside the threshold minus the other half.
class TempoDriftTracker {
  TempoDriftTracker({
    this.onTempoPercent = 2,
    this.offPercent = 5,
    this.hysteresisPercent = 1,
    this.minConfidence = 0.2,
  });

  /// Readings below this detector confidence aren't judged: the detector
  /// leans toward the song's BPM, so faint noise can land near the target
  /// and would otherwise look like "on tempo" or "drifting".
  final double minConfidence;

  final double onTempoPercent;
  final double offPercent;
  final double hysteresisPercent;

  DriftLevel _level = DriftLevel.onTempo;

  /// Forget the previous level (e.g. on a new song).
  void reset() => _level = DriftLevel.onTempo;

  /// Returns null when there's nothing to compare: no reading, no target, or
  /// a reading less confident than [minConfidence].
  TempoDrift? update(double heardBpm, double targetBpm, {double confidence = 1}) {
    if (heardBpm <= 0 || targetBpm <= 0 || confidence < minConfidence) {
      reset();
      return null;
    }

    // A band clearly at half or double the marking isn't "drifting": compare
    // against that octave of the target instead.
    var octave = 1.0;
    final ratio = heardBpm / targetBpm;
    if ((math.log(ratio) / math.ln2 - 1).abs() < 0.1) octave = 2;
    if ((math.log(ratio) / math.ln2 + 1).abs() < 0.1) octave = 0.5;
    final target = targetBpm * octave;

    final delta = heardBpm - target;
    final percent = delta / target * 100;
    final size = percent.abs();
    final h = hysteresisPercent / 2;

    // Raise the level once past threshold + h; lower it once below
    // threshold - h; otherwise keep the previous level.
    switch (_level) {
      case DriftLevel.onTempo:
        if (size > offPercent + h) {
          _level = DriftLevel.off;
        } else if (size > onTempoPercent + h) {
          _level = DriftLevel.drifting;
        }
      case DriftLevel.drifting:
        if (size > offPercent + h) {
          _level = DriftLevel.off;
        } else if (size < onTempoPercent - h) {
          _level = DriftLevel.onTempo;
        }
      case DriftLevel.off:
        if (size < onTempoPercent - h) {
          _level = DriftLevel.onTempo;
        } else if (size < offPercent - h) {
          _level = DriftLevel.drifting;
        }
    }

    return TempoDrift(
        level: _level, deltaBpm: delta, percent: percent, octave: octave);
  }
}
