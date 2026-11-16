import 'dart:convert';

import 'playlist.dart';

/// Plain-text setlist format for sharing and importing.
///
/// Export writes one song per line:
///
///     # SCBeatWiz setlist: Friday Gig
///     Superstition, 100, 4:26
///     Valerie, 118
///
/// Import is lenient so people can paste lists typed by hand:
/// `Superstition - 100`, `1. Valerie, 118 bpm`, `120 Song name`, with or
/// without a length (`4:26`). A time signature (`3/4`) or notes after ` | `
/// — written by older versions — are accepted and ignored. Lines starting
/// with `#` are comments, except a
/// `# Setlist: <name>` / `# Playlist: <name>` header, which names the
/// playlist. JSON (a playlist object or a list of them, as stored by the
/// app) is accepted too.

const String _headerPrefix = '# SCBeatWiz setlist: ';

/// Renders [playlist] as shareable text.
String playlistToText(Playlist playlist) {
  final b = StringBuffer('$_headerPrefix${playlist.name}\n');
  for (final s in playlist.items) {
    final parts = <String>[
      s.name.replaceAll(',', ' '), // keep the comma as the field separator
      '${s.bpm}',
      if (s.durationSeconds != null) formatDuration(s.durationSeconds!),
    ];
    b.write(parts.join(', '));
    b.write('\n');
  }
  return b.toString();
}

/// Result of [parsePlaylistText].
class PlaylistImport {
  /// The imported playlists (usually one). Empty if nothing was readable.
  final List<Playlist> playlists;

  /// Non-empty, non-comment lines that couldn't be read as a song.
  final List<String> skippedLines;

  const PlaylistImport(this.playlists, this.skippedLines);

  int get songCount =>
      playlists.fold(0, (n, p) => n + p.items.length);
}

/// Parses pasted text (or JSON) into playlists. [fallbackName] names a
/// playlist that has no header.
PlaylistImport parsePlaylistText(String text,
    {String fallbackName = 'Imported Setlist'}) {
  final trimmed = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    final fromJson = _tryJson(trimmed);
    if (fromJson != null) return PlaylistImport(fromJson, const []);
  }

  String? name;
  final songs = <SetlistItem>[];
  final skipped = <String>[];
  final header =
      RegExp(r'^#\s*(?:SCBeatWiz setlist|setlist|playlist)\s*:\s*(.+)$',
          caseSensitive: false);

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final m = header.firstMatch(line);
      if (m != null && name == null) name = m[1]!.trim();
      continue;
    }
    final song = _parseSongLine(line);
    if (song == null) {
      skipped.add(line);
    } else {
      songs.add(song);
    }
  }

  if (songs.isEmpty) return PlaylistImport(const [], skipped);
  return PlaylistImport(
      [Playlist(name?.isNotEmpty == true ? name! : fallbackName, songs)],
      skipped);
}

List<Playlist>? _tryJson(String text) {
  try {
    final decoded = jsonDecode(text);
    final list = decoded is List ? decoded : [decoded];
    final playlists = [
      for (final p in list) Playlist.fromJson(p as Map<String, dynamic>),
    ].where((p) => p.items.isNotEmpty).toList();
    return playlists.isEmpty ? null : playlists;
  } catch (_) {
    return null;
  }
}

final _numbering = RegExp(r'^\d{1,3}[.)]\s+');
final _timeSig = RegExp(r'(?<![\d/])(\d{1,2}/\d{1,2})(?![\d/])');
final _duration = RegExp(r'(?<![\d:])(\d{1,3}:[0-5]\d)(?![\d:])');
// "bpm" on its own or glued to the number ("118BPM").
final _bpmWord = RegExp(r'(?:(?<=\d)|\b)bpm\b', caseSensitive: false);
final _integer = RegExp(r'(?<![\w.:/])(\d{2,3})(?![\w.:/])');
final _separators = RegExp(r'^[\s,;\-–—·|]+|[\s,;\-–—·|]+$');

SetlistItem? _parseSongLine(String line) {
  // Notes after " | " (from older shares) are dropped.
  final bar = line.indexOf(' | ');
  if (bar >= 0) line = line.substring(0, bar);
  line = line.replaceFirst(_numbering, '');

  // A time signature (from older shares) is ignored, but must be removed so
  // its digits aren't taken for the BPM.
  line = line.replaceAll(_timeSig, ' ');

  int? durationSeconds;
  final dur = _duration.firstMatch(line);
  if (dur != null) {
    durationSeconds = parseDuration(dur[1]!);
    line = line.replaceRange(dur.start, dur.end, ' ');
  }

  line = line.replaceAll(_bpmWord, ' ');

  // The BPM is the last standalone 2-3 digit number in range, so song
  // titles that start with a number ("99 Problems, 90") still work.
  int? bpm;
  RegExpMatch? bpmMatch;
  for (final m in _integer.allMatches(line)) {
    final v = int.parse(m[1]!);
    if (v >= 30 && v <= 300) bpmMatch = m;
  }
  if (bpmMatch == null) return null;
  bpm = int.parse(bpmMatch[1]!);
  line = line.replaceRange(bpmMatch.start, bpmMatch.end, ' ');

  final name = line
      .replaceAll(RegExp(r'\s*[,;]\s*[,;\s]*'), ', ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll(_separators, '')
      .trim();

  return SetlistItem(name.isEmpty ? 'Unnamed Song' : name, bpm,
      durationSeconds: durationSeconds);
}
