/// Working state for show creation mode: the BPM being captured, the
/// half/double-time scale, and the pending song label. Pure Dart.
library;

import 'dart:math' as math;

import 'show_numbering.dart';

/// Half-time / double-time display modifier for the song being captured.
enum ShowScale {
  half(0.5),
  normal(1),
  twice(2);

  const ShowScale(this.factor);
  final double factor;
}

/// How the pending label advances after a commit.
enum ShowAdvance { whole, sub }

/// A song ready to append to the show's playlist.
typedef ShowSong = ({String name, int bpm});

class ShowDraft {
  ShowDraft({String pendingLabel = '1', this.advance = ShowAdvance.whole})
      : _pendingLabel = pendingLabel,
        _nextDefault = pendingLabel;

  static const int minBpm = 30;
  static const int maxBpm = 300;

  ShowAdvance advance;

  int? _bpm;
  // The BPM the user last settled on (capture, tap, nudge). Heard tempos are
  // folded by octaves to the one nearest it, so the readout doesn't jump
  // between 40, 80 and 160 when the detector changes its mind about the root.
  double? _anchor;
  ShowScale _scale = ShowScale.normal;
  String _pendingLabel;
  // Last parseable label, used when a free-text label like "intro" is
  // committed and the sequence should carry on from where it was.
  String _nextDefault;
  // The label just committed, while the pending label is still the untouched
  // whole-number advance from it. Letter + then goes back to a sub-song of it.
  ShowLabel? _justCommitted;

  /// The working BPM, or null before the first capture/tap/nudge.
  int? get bpm => _bpm;
  ShowScale get scale => _scale;

  /// The tempo the listener should favour (the working BPM), or null.
  double? get anchor => _anchor;
  String get pendingLabel => _pendingLabel;

  String _title = '';

  /// Optional song title; the committed name is "1a. Title".
  String get title => _title;
  set title(String v) => _title = v.trim();

  /// The name the song will get on commit: "1a. Title", or just "1a".
  String get pendingName {
    final label = _pendingLabel.trim();
    return _title.isEmpty ? label : '$label. $_title';
  }

  static int _clamp(num v) => v.round().clamp(minBpm, maxBpm);

  /// Folds [bpm] by powers of two to the octave nearest [anchor].
  static double foldToAnchor(double bpm, double anchor) {
    if (bpm <= 0 || anchor <= 0) return bpm;
    final octaves = (math.log(anchor / bpm) / math.ln2).round();
    return bpm * math.pow(2, octaves);
  }

  /// The heard tempo as the user wants to see it: scaled, then (once a BPM
  /// has been set) folded into the octave of the anchor.
  double shown(double heardBpm) {
    final scaled = heardBpm * _scale.factor;
    final a = _anchor;
    return a == null ? scaled : foldToAnchor(scaled, a);
  }

  /// Sets the working BPM from the heard tempo, scaled. Overwrites.
  void capture(double heardBpm) {
    _bpm = _clamp(shown(heardBpm));
    _anchor = _bpm!.toDouble();
  }

  /// What a capture would give right now (for the live readout).
  int scaled(double heardBpm) => _clamp(shown(heardBpm));

  /// Sets the working BPM directly (tap tempo); ignores the scale.
  void setBpm(double bpm) {
    _bpm = _clamp(bpm);
    _anchor = _bpm!.toDouble();
  }

  /// Adds [delta] to the working BPM; ignores the scale. No-op before a
  /// BPM has been set.
  void nudge(int delta) {
    final b = _bpm;
    if (b != null) {
      _bpm = _clamp(b + delta);
      _anchor = _bpm!.toDouble();
    }
  }

  /// Selects a scale. Selecting the active non-normal option returns to
  /// normal; options replace each other rather than stack. Drops the anchor,
  /// since the scale is the user's new octave choice.
  void selectScale(ShowScale s) {
    _anchor = null;
    _scale = (s == _scale && s != ShowScale.normal) ? ShowScale.normal : s;
  }

  /// Sets the label by hand; a parseable value becomes the base for later
  /// advances.
  void setPendingLabel(String label) {
    _pendingLabel = label;
    _justCommitted = null;
    if (ShowLabel.parse(label) != null) _nextDefault = label.trim();
  }

  ShowLabel get _stepBase =>
      ShowLabel.parse(_pendingLabel) ??
      ShowLabel.parse(_nextDefault) ??
      const ShowLabel(1);

  /// Bumps the song number up or down (minimum 1); the letter is dropped,
  /// so "3b" + 1 is "4". Starts from the last numeric label if the pending
  /// one is free text.
  void stepNumber(int delta) {
    final n = _stepBase.number + delta;
    setPendingLabel('${n < 1 ? 1 : n}');
  }

  /// Steps the letter: "3" → "3a" → "3b"; down again to "3a" → "3".
  ///
  /// Right after committing "1" (pending "2"), Letter + gives "1a" rather
  /// than "2a": the next song is a sub-song of the one just finished.
  void stepSuffix(int delta) {
    final prev = _justCommitted;
    if (prev != null && delta > 0) {
      var suffix = prev.suffix;
      for (var i = 0; i < delta; i++) {
        suffix = nextSuffix(suffix);
      }
      setPendingLabel('${prev.number}$suffix');
      return;
    }
    final base = _stepBase;
    var suffix = base.suffix;
    for (var i = 0; i < delta.abs(); i++) {
      suffix = delta > 0 ? nextSuffix(suffix) : prevSuffix(suffix);
    }
    setPendingLabel('${base.number}$suffix');
  }

  /// Whether [label] matches the number of one of the [existing] song names
  /// (case-insensitive; "1a. Title" has the number "1a").
  static bool isDuplicate(String label, Iterable<String> existing) {
    final l = label.trim().toLowerCase();
    if (l.isEmpty) return false;
    return existing.any((e) {
      final name = e.trim().toLowerCase();
      return name == l || name.startsWith('$l. ');
    });
  }

  /// Finishes the current song: returns it and resets the BPM and scale,
  /// advancing the pending label. Null if there is no BPM or label yet.
  ShowSong? commit() {
    final b = _bpm;
    final label = _pendingLabel.trim();
    if (b == null || label.isEmpty) return null;
    final name = pendingName;
    final next = advance == ShowAdvance.whole
        ? nextWholeLabel(label)
        : nextSubLabel(label);
    _pendingLabel = next ?? _nextDefault;
    if (next != null) _nextDefault = next;
    _bpm = null;
    _anchor = null;
    _scale = ShowScale.normal;
    _title = '';
    final committed = ShowLabel.parse(label);
    _justCommitted = advance == ShowAdvance.whole && next != null
        ? committed
        : null;
    return (name: name, bpm: b);
  }

  /// Drops the working BPM and scale (leaving the mode); the label stays.
  void resetWorking() {
    _bpm = null;
    _anchor = null;
    _scale = ShowScale.normal;
  }
}
