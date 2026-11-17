import 'package:beth/tempo_detector.dart';
import 'package:beth/tempo_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 1, 1);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));
  TempoEstimate est(double bpm, [double conf = 0.5]) => TempoEstimate(bpm, conf);

  /// Feeds an estimate every 0.5 s from [from] to [to]; returns the time of
  /// lock, or null.
  double? feed(TempoLock lock, double from, double to, TempoEstimate? e) {
    for (var s = from; s <= to + 1e-9; s += 0.5) {
      if (lock.update(e, at(s))) return s;
    }
    return null;
  }

  test('does nothing until armed', () {
    final lock = TempoLock();
    expect(feed(lock, 0, 10, est(120)), isNull);
  });

  test('locks after holding close for 3 s', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 10, est(121.5)), 3.0);
    expect(lock.isArmed, isFalse);
  });

  test('fires only once', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 5, est(120)), isNotNull);
    expect(feed(lock, 5.5, 20, est(120)), isNull);
  });

  test('ignores tempos outside tolerance', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 10, est(125)), isNull); // 3% of 120 = 3.6
    expect(feed(lock, 0, 10, est(60)), isNull); // half time is not a match
  });

  test('uses a 2 BPM floor for slow tempos', () {
    final lock = TempoLock()..arm(60); // 3% = 1.8, floor 2
    expect(feed(lock, 0, 10, est(61.9)), isNotNull);
  });

  test('ignores low-confidence readings', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 10, est(120, 0.1)), isNull);
  });

  test('a stray reading restarts the hold', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 2, est(120)), isNull);
    expect(lock.update(est(140), at(2.5)), isFalse);
    expect(lock.update(null, at(3.0)), isFalse); // silence also resets
    expect(feed(lock, 3.5, 10, est(120)), 6.5);
  });

  test('re-arming resets the hold', () {
    final lock = TempoLock()..arm(120);
    expect(feed(lock, 0, 2, est(120)), isNull);
    lock.arm(90);
    expect(feed(lock, 2.5, 10, est(120)), isNull);
  });
}
