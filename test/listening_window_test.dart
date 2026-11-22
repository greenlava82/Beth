import 'package:flutter_test/flutter_test.dart';
import 'package:beth/listening_window.dart';

void main() {
  test('windows are centred on the target on a log scale', () {
    expect(ListeningWindow.normal.rangeAround(120), (90.0, 160.0));
    expect(ListeningWindow.tight.rangeAround(120), (105.0, 140.0));
    expect(ListeningWindow.wide.rangeAround(120), (80.0, 180.0));
  });

  test('slow songs get a proportionally narrower window', () {
    expect(ListeningWindow.normal.rangeAround(60), (45.0, 80.0));
  });

  test('windows stay within the limits, keeping their width', () {
    final (lo, hi) = ListeningWindow.wide.rangeAround(45);
    expect(lo, 40);
    expect(hi, greaterThan(75));
    final (lo2, hi2) = ListeningWindow.wide.rangeAround(200);
    expect(hi2, 220);
    expect(lo2, lessThan(150));
  });

  test('at least 10 BPM wide', () {
    final (lo, hi) = ListeningWindow.tight.rangeAround(40);
    expect(hi - lo, greaterThanOrEqualTo(10));
  });

  test('old saved ranges map to the nearest preset', () {
    expect(ListeningWindow.fromRange(90, 160), ListeningWindow.normal);
    expect(ListeningWindow.fromRange(100, 135), ListeningWindow.tight);
    expect(ListeningWindow.fromRange(60, 180), ListeningWindow.wide);
    expect(ListeningWindow.fromRange(0, 0), ListeningWindow.normal);
  });
}
