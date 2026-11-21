import 'package:beth/tempo_detector.dart';
import 'package:beth/tempo_display_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 20);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));
  TempoEstimate est(double conf, [double bpm = 120]) => TempoEstimate(bpm, conf);

  test('stays on Listening until confidence reaches the show threshold', () {
    final g = TempoDisplayGate(showAbove: 0.2, hysteresis: 0.1);
    expect(g.update(est(0.15), at(0)), 0);
    expect(g.update(est(0.2), at(0.5)), 120);
  });

  test('hysteresis keeps the BPM while confidence dips above the lower bar',
      () {
    final g = TempoDisplayGate(showAbove: 0.2, hysteresis: 0.1, holdSeconds: 0);
    g.update(est(0.5, 100), at(0));
    expect(g.update(est(0.12, 101), at(1)), 101);
    expect(g.update(est(0.05, 102), at(2)), 0); // below 0.1, no hold
  });

  test('a weak reading holds the last good BPM, then drops it', () {
    final g = TempoDisplayGate(showAbove: 0.2, hysteresis: 0.1, holdSeconds: 3);
    g.update(est(0.6, 98), at(0));
    expect(g.update(est(0.02, 140), at(1)), 98); // held, weak value ignored
    expect(g.update(null, at(2.9)), 98);
    expect(g.update(null, at(3)), 0);
    // Once dropped it needs the full show threshold again.
    expect(g.update(est(0.15), at(4)), 0);
  });

  test('tick expires a hold with no new estimates', () {
    final g = TempoDisplayGate(holdSeconds: 2);
    g.update(est(0.6), at(0));
    expect(g.tick(at(1.9)), 120);
    expect(g.tick(at(2)), 0);
  });

  test('a good reading refreshes the hold', () {
    final g = TempoDisplayGate(holdSeconds: 3);
    g.update(est(0.6), at(0));
    g.update(est(0.5), at(2.5));
    expect(g.tick(at(5)), 120);
    expect(g.tick(at(5.5)), 0);
  });

  test('reset clears the readout', () {
    final g = TempoDisplayGate();
    g.update(est(0.6), at(0));
    g.reset();
    expect(g.bpm, 0);
    expect(g.confidence, 0);
  });
}
