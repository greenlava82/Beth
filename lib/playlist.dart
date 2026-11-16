import 'dart:convert';

/// Time signatures offered in the song editor.
const List<String> timeSignatures = [
  '2/4', '3/4', '4/4', '5/4', '6/8', '7/8', '9/8', '12/8', //
];

/// One song in a setlist.
class SetlistItem {
  String name;
  int bpm;

  /// e.g. "4/4"; the metronome accents the first of [beatsPerBar] beats.
  String timeSignature;

  /// Free-form notes: key, cues, who starts…
  String notes;

  /// Expected length, if known.
  int? durationSeconds;

  SetlistItem(
    this.name,
    this.bpm, {
    this.timeSignature = '4/4',
    this.notes = '',
    this.durationSeconds,
  });

  /// Beats in one bar (the time signature's top number).
  int get beatsPerBar {
    final n = int.tryParse(timeSignature.split('/').first);
    return (n == null || n < 1) ? 4 : n;
  }

  SetlistItem copy() => SetlistItem(name, bpm,
      timeSignature: timeSignature,
      notes: notes,
      durationSeconds: durationSeconds);

  Map<String, dynamic> toJson() => {
        'name': name,
        'bpm': bpm,
        'timeSignature': timeSignature,
        if (notes.isNotEmpty) 'notes': notes,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
      };

  factory SetlistItem.fromJson(Map<String, dynamic> json) {
    final ts = json['timeSignature'] as String?;
    return SetlistItem(
      (json['name'] as String?) ?? 'Unnamed Song',
      (json['bpm'] as num?)?.round() ?? 120,
      timeSignature: (ts != null && timeSignatures.contains(ts)) ? ts : '4/4',
      notes: (json['notes'] as String?) ?? '',
      durationSeconds: (json['durationSeconds'] as num?)?.round(),
    );
  }
}

/// "3:05" for 185 seconds.
String formatDuration(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// Parses "3:05" or "3" (minutes) into seconds. Returns null for blank or
/// invalid input.
int? parseDuration(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'^(\d{1,3})(?::([0-5]\d))?$').firstMatch(t);
  if (m == null) return null;
  final total = int.parse(m[1]!) * 60 + int.parse(m[2] ?? '0');
  return total > 0 ? total : null;
}

/// Total of the known song durations, and how many songs have one.
({int seconds, int known}) playlistDuration(Playlist p) {
  var seconds = 0, known = 0;
  for (final s in p.items) {
    if (s.durationSeconds != null) {
      seconds += s.durationSeconds!;
      known++;
    }
  }
  return (seconds: seconds, known: known);
}

/// A named, ordered setlist.
class Playlist {
  String name;
  List<SetlistItem> items;

  Playlist(this.name, this.items);

  /// Deep copy, e.g. for duplicating a playlist.
  Playlist copy({String? name}) =>
      Playlist(name ?? this.name, [for (final s in items) s.copy()]);

  Map<String, dynamic> toJson() => {
        'name': name,
        'items': items.map((item) => item.toJson()).toList(),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      (json['name'] as String?) ?? 'Untitled Playlist',
      ((json['items'] as List<dynamic>?) ?? const [])
          .map((item) => SetlistItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// The setlist a fresh install starts with.
List<Playlist> defaultPlaylists() => [
      Playlist('Default Setlist', [
        SetlistItem('Song 1 (Slow)', 80),
        SetlistItem('Song 2 (Upbeat)', 120),
        SetlistItem('Song 3 (Fast)', 160),
        SetlistItem('Song 4 (Groove)', 105),
      ]),
    ];

/// Serialises playlists for storage.
String encodePlaylists(List<Playlist> playlists) =>
    jsonEncode(playlists.map((p) => p.toJson()).toList());

/// Parses stored playlists. Returns null if [json] is missing or unreadable,
/// so the caller can fall back to defaults; missing fields get defaults.
List<Playlist>? decodePlaylists(String? json) {
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final playlists = decoded
        .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
        .toList();
    return playlists.isEmpty ? null : playlists;
  } catch (_) {
    return null;
  }
}
