import 'package:flutter_test/flutter_test.dart';
import 'package:beth/show_numbering.dart';

void main() {
  test('parse', () {
    expect(ShowLabel.parse('3'), const ShowLabel(3));
    expect(ShowLabel.parse(' 3B '), const ShowLabel(3, 'b'));
    expect(ShowLabel.parse('12ab'), const ShowLabel(12, 'ab'));
    expect(ShowLabel.parse('intro'), isNull);
    expect(ShowLabel.parse('a3'), isNull);
    expect(ShowLabel.parse(''), isNull);
  });

  test('nextSuffix runs a..z, aa, ab', () {
    expect(nextSuffix(''), 'a');
    expect(nextSuffix('a'), 'b');
    expect(nextSuffix('y'), 'z');
    expect(nextSuffix('z'), 'aa');
    expect(nextSuffix('aa'), 'ab');
    expect(nextSuffix('az'), 'ba');
    expect(nextSuffix('zz'), 'aaa');
  });

  test('next whole and sub', () {
    expect(nextWholeLabel('3b'), '4');
    expect(nextWholeLabel('3'), '4');
    expect(nextSubLabel('3'), '3a');
    expect(nextSubLabel('3a'), '3b');
    expect(nextWholeLabel('intro'), isNull);
    expect(nextSubLabel('intro'), isNull);
  });

  test('ordering', () {
    final labels = ['10', '2b', 'intro', '2', '2aa', '2z', '2a'];
    labels.sort(compareShowLabels);
    expect(labels, ['2', '2a', '2b', '2z', '2aa', '10', 'intro']);
  });
}
