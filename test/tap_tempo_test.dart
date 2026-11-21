import 'package:flutter_test/flutter_test.dart';
import 'package:beth/tap_tempo.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  test('first tap gives nothing, second gives a tempo', () {
    final t = TapTempo();
    expect(t.tap(ms(0)), isNull);
    expect(t.tap(ms(500)), closeTo(120, 0.01));
  });

  test('averages the last taps only', () {
    final t = TapTempo(maxTaps: 4);
    // Slow start (1000 ms), then steady 500 ms.
    t.tap(ms(0));
    t.tap(ms(1000));
    t.tap(ms(1500));
    t.tap(ms(2000));
    // Window is now 1000..2000 + this tap: all 500 ms intervals.
    expect(t.tap(ms(2500)), closeTo(120, 0.01));
  });

  test('idle gap restarts the sequence', () {
    final t = TapTempo();
    t.tap(ms(0));
    t.tap(ms(500));
    expect(t.tap(ms(5000)), isNull);
    expect(t.tapCount, 1);
    expect(t.tap(ms(5400)), closeTo(150, 0.01));
  });

  test('duplicate timestamps are ignored', () {
    final t = TapTempo();
    t.tap(ms(100));
    expect(t.tap(ms(100)), isNull);
    expect(t.tapCount, 1);
  });

  test('reset clears taps', () {
    final t = TapTempo()..tap(ms(0));
    t.reset();
    expect(t.tapCount, 0);
  });
}
