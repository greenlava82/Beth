/// How far either side of a song's BPM the detector favours: the setlist
/// mode's "listening window". Pure Dart.
library;

import 'dart:math' as math;

enum ListeningWindow {
  tight('Tight', '±15%', 1.15),
  normal('Normal', '±33%', 1.33),
  wide('Wide', '±50%', 1.5);

  const ListeningWindow(this.label, this.percent, this.factor);

  final String label;

  /// Approximate half-width, for display.
  final String percent;

  /// The window runs from target / factor to target * factor.
  final double factor;

  /// High / low ratio of the window.
  double get ratio => factor * factor;

  /// The preset whose ratio is nearest [max] / [min] (log scale). Used to
  /// carry over the old saved min/max range slider.
  static ListeningWindow fromRange(double min, double max) {
    if (min <= 0 || max <= min) return normal;
    final r = math.log(max / min);
    var best = normal;
    for (final w in values) {
      if ((math.log(w.ratio) - r).abs() < (math.log(best.ratio) - r).abs()) {
        best = w;
      }
    }
    return best;
  }

  /// The window around [target], snapped to 5 BPM and kept within
  /// [limitMin]..[limitMax] (preserving the width where possible), at least
  /// 10 BPM wide.
  (double, double) rangeAround(double target,
      {double limitMin = 40, double limitMax = 220}) {
    const step = 5.0;
    double snap(double v) => (v / step).round() * step;
    var lo = snap(target / factor);
    var hi = snap(target * factor);
    if (lo < limitMin) {
      lo = limitMin;
      hi = math.min(limitMax, snap(lo * ratio));
    } else if (hi > limitMax) {
      hi = limitMax;
      lo = math.max(limitMin, snap(hi / ratio));
    }
    if (hi - lo < 10) hi = math.min(limitMax, lo + 10);
    return (lo, hi);
  }
}
