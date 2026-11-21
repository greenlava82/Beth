/// Tap-tempo: averages the intervals of the last few taps. Pure Dart.
library;

class TapTempo {
  TapTempo({
    this.maxTaps = 6,
    this.idleReset = const Duration(seconds: 2),
  });

  /// Number of taps averaged (so maxTaps - 1 intervals).
  final int maxTaps;

  /// A gap longer than this starts a new tap sequence.
  final Duration idleReset;

  final List<Duration> _taps = [];

  int get tapCount => _taps.length;

  /// Registers a tap at [now] (a monotonic timestamp, e.g. a Stopwatch's
  /// elapsed). Returns the BPM once at least two taps are in, else null.
  double? tap(Duration now) {
    if (_taps.isNotEmpty && now - _taps.last > idleReset) _taps.clear();
    // Ignore taps that arrive out of order or at the same instant.
    if (_taps.isNotEmpty && now <= _taps.last) return null;
    _taps.add(now);
    if (_taps.length > maxTaps) _taps.removeAt(0);
    if (_taps.length < 2) return null;
    final span = _taps.last - _taps.first;
    final avgMicros = span.inMicroseconds / (_taps.length - 1);
    return 60e6 / avgMicros;
  }

  void reset() => _taps.clear();
}
