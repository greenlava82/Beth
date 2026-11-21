/// Working state for show creation mode: the BPM being captured, the
/// half/double-time scale, and the pending song label. Pure Dart.
library;

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
  ShowScale _scale = ShowScale.normal;
  String _pendingLabel;
  // Last parseable label, used when a free-text label like "intro" is
  // committed and the sequence should carry on from where it was.
  String _nextDefault;

  /// The working BPM, or null before the first capture/tap/nudge.
  int? get bpm => _bpm;
  ShowScale get scale => _scale;
  String get pendingLabel => _pendingLabel;

  static int _clamp(num v) => v.round().clamp(minBpm, maxBpm);

  /// Sets the working BPM from the heard tempo, scaled. Overwrites.
  void capture(double heardBpm) => _bpm = _clamp(heardBpm * _scale.factor);

  /// What a capture would give right now (for the live readout).
  int scaled(double heardBpm) => _clamp(heardBpm * _scale.factor);

  /// Sets the working BPM directly (tap tempo); ignores the scale.
  void setBpm(double bpm) => _bpm = _clamp(bpm);

  /// Adds [delta] to the working BPM; ignores the scale. No-op before a
  /// BPM has been set.
  void nudge(int delta) {
    final b = _bpm;
    if (b != null) _bpm = _clamp(b + delta);
  }

  /// Selects a scale. Selecting the active non-normal option returns to
  /// normal; options replace each other rather than stack.
  void selectScale(ShowScale s) {
    _scale = (s == _scale && s != ShowScale.normal) ? ShowScale.normal : s;
  }

  /// Sets the label by hand; a parseable value becomes the base for later
  /// advances.
  void setPendingLabel(String label) {
    _pendingLabel = label;
    if (ShowLabel.parse(label) != null) _nextDefault = label.trim();
  }

  /// Whether [label] matches one of [existing] (case-insensitive).
  static bool isDuplicate(String label, Iterable<String> existing) {
    final l = label.trim().toLowerCase();
    return l.isNotEmpty && existing.any((e) => e.trim().toLowerCase() == l);
  }

  /// Finishes the current song: returns it and resets the BPM and scale,
  /// advancing the pending label. Null if there is no BPM or label yet.
  ShowSong? commit() {
    final b = _bpm;
    final name = _pendingLabel.trim();
    if (b == null || name.isEmpty) return null;
    final next = advance == ShowAdvance.whole
        ? nextWholeLabel(name)
        : nextSubLabel(name);
    _pendingLabel = next ?? _nextDefault;
    if (next != null) _nextDefault = next;
    _bpm = null;
    _scale = ShowScale.normal;
    return (name: name, bpm: b);
  }

  /// Drops the working BPM and scale (leaving the mode); the label stays.
  void resetWorking() {
    _bpm = null;
    _scale = ShowScale.normal;
  }
}
