/// Song numbering for show creation mode: "1", "2a", "3b", "aa"-style
/// suffixes. Pure Dart.
library;

/// A label split into a whole number and a letter suffix ("3b" → 3, "b").
class ShowLabel {
  const ShowLabel(this.number, [this.suffix = '']);

  final int number;

  /// Lower-case letters a..z, aa, ab, …; empty for a plain number.
  final String suffix;

  /// Parses "3", "3a", "12bc" (case-insensitive, surrounding spaces ignored).
  /// Returns null for anything else ("intro", "", "a3").
  static ShowLabel? parse(String text) {
    final m = RegExp(r'^(\d+)([a-z]*)$').firstMatch(text.trim().toLowerCase());
    if (m == null) return null;
    final number = int.tryParse(m.group(1)!);
    if (number == null) return null;
    return ShowLabel(number, m.group(2)!);
  }

  @override
  String toString() => '$number$suffix';

  @override
  bool operator ==(Object other) =>
      other is ShowLabel && other.number == number && other.suffix == suffix;

  @override
  int get hashCode => Object.hash(number, suffix);
}

/// Next letter suffix: '' → 'a', 'a' → 'b', 'z' → 'aa', 'az' → 'ba'.
String nextSuffix(String suffix) {
  if (suffix.isEmpty) return 'a';
  final chars = suffix.codeUnits.toList();
  var i = chars.length - 1;
  while (i >= 0) {
    if (chars[i] < 0x7a) {
      chars[i]++;
      return String.fromCharCodes(chars);
    }
    chars[i] = 0x61;
    i--;
  }
  return 'a${String.fromCharCodes(chars)}';
}

/// "3b" → "4", "3" → "4". Unparseable labels return null.
String? nextWholeLabel(String label) {
  final l = ShowLabel.parse(label);
  return l == null ? null : '${l.number + 1}';
}

/// "3" → "3a", "3a" → "3b". Unparseable labels return null.
String? nextSubLabel(String label) {
  final l = ShowLabel.parse(label);
  return l == null ? null : '${l.number}${nextSuffix(l.suffix)}';
}

/// Orders labels: by number, then suffix (shorter first, then alphabetical,
/// so "z" < "aa"). Unparseable labels sort after parseable ones, by text.
int compareShowLabels(String a, String b) {
  final la = ShowLabel.parse(a);
  final lb = ShowLabel.parse(b);
  if (la == null && lb == null) return a.compareTo(b);
  if (la == null) return 1;
  if (lb == null) return -1;
  if (la.number != lb.number) return la.number.compareTo(lb.number);
  if (la.suffix.length != lb.suffix.length) {
    return la.suffix.length.compareTo(lb.suffix.length);
  }
  return la.suffix.compareTo(lb.suffix);
}
