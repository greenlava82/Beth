import 'package:flutter_test/flutter_test.dart';
import 'package:scbeatwiz/tempo_drift.dart';

void main() {
  DriftLevel level(double heard, [double target = 120]) =>
      TempoDriftTracker().update(heard, target)!.level;

  test('levels from a fresh tracker', () {
    expect(level(120), DriftLevel.onTempo);
    expect(level(122), DriftLevel.onTempo); // 1.7%
    expect(level(124), DriftLevel.drifting); // 3.3%
    expect(level(116.5), DriftLevel.drifting); // -2.9%
    expect(level(128), DriftLevel.off); // 6.7%
    expect(level(112), DriftLevel.off); // -6.7%
  });

  test('reports direction and size', () {
    final d = TempoDriftTracker().update(123, 120)!;
    expect(d.deltaBpm, closeTo(3, 1e-9));
    expect(d.percent, closeTo(2.5, 1e-9));
    expect(d.isRushing, isTrue);
    final s = TempoDriftTracker().update(116, 120)!;
    expect(s.isRushing, isFalse);
    expect(s.deltaBpm, closeTo(-4, 1e-9));
  });

  test('hysteresis stops flicker at a threshold', () {
    final t = TempoDriftTracker();
    // 2.4% sits between 2% and 2.5%: stays on tempo coming from on tempo…
    expect(t.update(122.9, 120)!.level, DriftLevel.onTempo);
    // …enters drifting past 2.5%…
    expect(t.update(123.2, 120)!.level, DriftLevel.drifting);
    // …and stays drifting back at 2.4%…
    expect(t.update(122.9, 120)!.level, DriftLevel.drifting);
    // …until under 1.5%.
    expect(t.update(121.7, 120)!.level, DriftLevel.onTempo);
  });

  test('hysteresis between drifting and off', () {
    final t = TempoDriftTracker();
    expect(t.update(126.8, 120)!.level, DriftLevel.off); // 5.7%
    expect(t.update(126.0, 120)!.level, DriftLevel.off); // 5.0%: hold
    expect(t.update(125.2, 120)!.level, DriftLevel.drifting); // 4.3%
    expect(t.update(125.9, 120)!.level, DriftLevel.drifting); // 4.9%: hold
  });

  test('half and double time are compared to that octave', () {
    final dbl = TempoDriftTracker().update(241, 120)!;
    expect(dbl.octave, 2);
    expect(dbl.level, DriftLevel.onTempo);
    expect(dbl.deltaBpm, closeTo(1, 1e-9));
    final half = TempoDriftTracker().update(57, 120)!;
    expect(half.octave, 0.5);
    expect(half.level, DriftLevel.drifting); // 57 vs 60: -5%
    expect(half.isHalfOrDoubleTime, isTrue);
  });

  test('no reading or no target gives null and resets', () {
    final t = TempoDriftTracker();
    expect(t.update(130, 120)!.level, DriftLevel.off);
    expect(t.update(0, 120), isNull);
    expect(t.update(123.5, 120)!.level, DriftLevel.drifting); // fresh, not "off"
    expect(t.update(120, 0), isNull);
  });

  test('weak readings are not judged', () {
    final t = TempoDriftTracker();
    expect(t.update(120, 120, confidence: 0.13), isNull);
    expect(t.update(152, 160, confidence: 0.14), isNull);
    expect(t.update(120, 120, confidence: 0.2)!.level, DriftLevel.onTempo);
  });

  test('a weak reading resets the hysteresis', () {
    final t = TempoDriftTracker();
    expect(t.update(130, 120, confidence: 0.9)!.level, DriftLevel.off);
    expect(t.update(130, 120, confidence: 0.05), isNull);
    // Fresh start: 3.3% enters "drifting", not the previous "off".
    expect(t.update(124, 120, confidence: 0.9)!.level, DriftLevel.drifting);
  });
}
