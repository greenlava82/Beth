import 'dart:convert';

/// One song in a setlist.
class SetlistItem {
  String name;
  int bpm;

  SetlistItem(this.name, this.bpm);

  SetlistItem copy() => SetlistItem(name, bpm);

  Map<String, dynamic> toJson() => {
        'name': name,
        'bpm': bpm,
      };

  factory SetlistItem.fromJson(Map<String, dynamic> json) {
    return SetlistItem(
      (json['name'] as String?) ?? 'Unnamed Song',
      (json['bpm'] as num?)?.round() ?? 120,
    );
  }
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
