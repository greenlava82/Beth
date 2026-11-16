import 'tempo_detector.dart';

/// Decides when the detected tempo has "locked on" to a target BPM, so the
/// app can stop the count-in metronome and let the player follow the band.
///
/// Arm it with the song's marking when the song starts. Feed it every new
/// detector estimate; [update] returns true once — the first time the
/// estimate has stayed within tolerance of the target, with enough
/// confidence, for [holdSeconds]. After that it disarms itself.
class TempoLock {
  TempoLock({
    this.holdSeconds = 3,
    this.minConfidence = 0.2,
    this.tolerancePercent = 3,
    this.minToleranceBpm = 2,
  });

  /// How long the reading must stay close before it counts as locked.
  final double holdSeconds;

  /// Minimum detector confidence ("fair" or better).
  final double minConfidence;

  /// Allowed difference from the target: the larger of [tolerancePercent]
  /// of the target and [minToleranceBpm].
  final double tolerancePercent;
  final double minToleranceBpm;

  double? _target;
  DateTime? _closeSince;

  bool get isArmed => _target != null;
  double? get target => _target;

  /// Start watching for a lock on [targetBpm].
  void arm(double targetBpm) {
    _target = targetBpm;
    _closeSince = null;
  }

  void disarm() {
    _target = null;
    _closeSince = null;
  }

  /// Whether [bpm] is within tolerance of [targetBpm].
  bool isClose(double bpm, double targetBpm) {
    final tol = (targetBpm * tolerancePercent / 100)
        .clamp(minToleranceBpm, double.infinity);
    return (bpm - targetBpm).abs() <= tol;
  }

  /// Feed the latest estimate (null = silence). Returns true exactly once,
  /// when the lock is acquired.
  bool update(TempoEstimate? estimate, DateTime now) {
    final target = _target;
    if (target == null) return false;
    final qualifies = estimate != null &&
        estimate.confidence >= minConfidence &&
        isClose(estimate.bpm, target);
    if (!qualifies) {
      _closeSince = null;
      return false;
    }
    _closeSince ??= now;
    final heldMs = now.difference(_closeSince!).inMilliseconds;
    if (heldMs >= holdSeconds * 1000) {
      disarm();
      return true;
    }
    return false;
  }
}
