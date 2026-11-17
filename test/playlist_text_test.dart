import 'package:flutter_test/flutter_test.dart';
import 'package:beth/playlist.dart';
import 'package:beth/playlist_text.dart';

void main() {
  SetlistItem one(String line) {
    final r = parsePlaylistText(line);
    expect(r.playlists, hasLength(1), reason: line);
    return r.playlists.single.items.single;
  }

  group('export', () {
    test('writes header and one line per song', () {
      final text = playlistToText(Playlist('Friday Gig', [
        SetlistItem('Superstition', 100, durationSeconds: 266),
        SetlistItem('Valerie', 118),
        SetlistItem('Waltz, op. 2', 150),
      ]));
      expect(
          text,
          '# Beth setlist: Friday Gig\n'
          'Superstition, 100, 4:26\n'
          'Valerie, 118\n'
          'Waltz  op. 2, 150\n');
    });

    test('round-trips through import', () {
      final original = Playlist('Set A', [
        SetlistItem('Superstition', 100, durationSeconds: 266),
        SetlistItem('Valerie', 118),
      ]);
      final back = parsePlaylistText(playlistToText(original)).playlists.single;
      expect(back.name, 'Set A');
      expect(back.items.map((s) => s.name), ['Superstition', 'Valerie']);
      expect(back.items.map((s) => s.bpm), [100, 118]);
      expect(back.items[0].durationSeconds, 266);
      expect(back.items[1].durationSeconds, isNull);
    });
  });

  group('import of hand-typed lists', () {
    test('common separators', () {
      expect(one('Superstition, 100').name, 'Superstition');
      expect(one('Superstition - 100').bpm, 100);
      expect(one('Superstition – 100').name, 'Superstition');
      expect(one('Superstition 100').name, 'Superstition');
      expect(one('Superstition\t100').bpm, 100);
    });

    test('numbering, bpm word and BPM first', () {
      final a = one('1. Valerie, 118 bpm');
      expect([a.name, a.bpm], ['Valerie', 118]);
      final b = one('12) Valerie 118BPM');
      expect(b.bpm, isNot(12));
      final c = one('118 Valerie');
      expect([c.name, c.bpm], ['Valerie', 118]);
    });

    test('titles containing numbers', () {
      final a = one('99 Problems, 90');
      expect([a.name, a.bpm], ['99 Problems', 90]);
      final b = one('Summer of 69, 139');
      expect([b.name, b.bpm], ['Summer of 69', 139]);
    });

    test('length anywhere; a time signature is ignored', () {
      final s = one('Blue Rondo, 3:45, 9/8, 168');
      expect(s.name, 'Blue Rondo');
      expect(s.bpm, 168);
      expect(s.durationSeconds, 225);
      // "12/8" must not be mistaken for a BPM of 12 or the title.
      final t = one('Tango, 12/8, 120');
      expect([t.name, t.bpm], ['Tango', 120]);
    });

    test('notes after " | " (older shares) are dropped', () {
      final s = one('Superstition, 100, 4/4, 4:26 | Clav intro / horns');
      expect([s.name, s.bpm, s.durationSeconds], ['Superstition', 100, 266]);
    });

    test('header names the playlist; other comments ignored', () {
      final r = parsePlaylistText('''
# Setlist: Wedding
# first set
Song A, 100

Song B, 120
''');
      expect(r.playlists.single.name, 'Wedding');
      expect(r.songCount, 2);
      expect(r.skippedLines, isEmpty);
    });

    test('reads setlists shared under the old SCBeatWiz name', () {
      final r = parsePlaylistText('# SCBeatWiz setlist: Old Gig\nSong A, 100');
      expect(r.playlists.single.name, 'Old Gig');
    });

    test('unreadable lines are skipped and reported', () {
      final r = parsePlaylistText('Song A, 100\nIntermission\nSong B, 500\n');
      expect(r.songCount, 1);
      expect(r.skippedLines, ['Intermission', 'Song B, 500']);
    });

    test('no header uses the fallback name', () {
      final r = parsePlaylistText('A, 100', fallbackName: 'Pasted');
      expect(r.playlists.single.name, 'Pasted');
    });

    test('nothing readable gives no playlists', () {
      final r = parsePlaylistText('hello\nworld');
      expect(r.playlists, isEmpty);
      expect(r.skippedLines, hasLength(2));
    });
  });

  group('backup', () {
    final playlists = [
      Playlist('Friday Gig', [
        SetlistItem('Superstition', 100, durationSeconds: 266),
        SetlistItem('Valerie', 118),
      ]),
      Playlist('Ideas', []),
      Playlist('Ça va', [SetlistItem('Waltz, op. 2', 150)]),
    ];

    test('round-trips every playlist, including empty ones', () {
      final text = playlistsToBackup(playlists,
          savedAt: DateTime.utc(2026, 11, 17, 20, 30));
      final r = parsePlaylistText(text);
      expect(r.isBackup, isTrue);
      expect(r.skippedLines, isEmpty);
      expect(r.playlists.map((p) => p.name), ['Friday Gig', 'Ideas', 'Ça va']);
      expect(r.playlists[0].items.map((s) => s.bpm), [100, 118]);
      expect(r.playlists[0].items[0].durationSeconds, 266);
      expect(r.playlists[1].items, isEmpty);
      // Commas in titles survive (unlike the one-line text format).
      expect(r.playlists[2].items.single.name, 'Waltz, op. 2');
      expect(r.songCount, 3);
    });

    test('is labelled and versioned', () {
      final text = playlistsToBackup(playlists,
          savedAt: DateTime.utc(2026, 11, 17, 20, 30));
      expect(text, contains('"kind": "$backupKind"'));
      expect(text, contains('"version": $backupVersion'));
      expect(text, contains('"saved": "2026-11-17T20:30:00.000Z"'));
    });

    test('tolerates unknown fields and newer versions', () {
      final r = parsePlaylistText('{"kind":"$backupKind","version":99,'
          '"theme":"dark","playlists":[{"name":"A","items":'
          '[{"name":"X","bpm":90,"key":"Am"}]}]}');
      expect(r.isBackup, isTrue);
      expect(r.playlists.single.items.single.bpm, 90);
    });

    test('accepts backups saved under the old SCBeatWiz name', () {
      final r = parsePlaylistText('{"kind":"scbeatwiz-playlists","version":1,'
          '"playlists":[{"name":"Old","items":[]}]}');
      expect(r.isBackup, isTrue);
      expect(r.playlists.single.name, 'Old');
    });

    test('a backup with no playlists imports nothing', () {
      final r = parsePlaylistText('{"kind":"$backupKind","playlists":[]}');
      expect(r.playlists, isEmpty);
    });

    test('shared playlists are not backups', () {
      expect(parsePlaylistText('A, 100').isBackup, isFalse);
      final json = encodePlaylists(defaultPlaylists());
      expect(parsePlaylistText(json).isBackup, isFalse);
    });

    test('file name carries the date', () {
      expect(backupFileName(DateTime(2026, 3, 7)),
          'Beth playlists 2026-03-07.json');
    });
  });

  group('JSON import', () {
    test('single playlist object', () {
      final r = parsePlaylistText(
          '{"name":"J","items":[{"name":"A","bpm":101,"timeSignature":"6/8"}]}');
      // Older JSON with a time signature still imports (the field is ignored).
      final p = r.playlists.single;
      expect(p.name, 'J');
      expect(p.items.single.bpm, 101);
    });

    test('list of playlists, as stored by the app', () {
      final json = encodePlaylists(defaultPlaylists() +
          [Playlist('Two', [SetlistItem('X', 90)])]);
      final r = parsePlaylistText(json);
      expect(r.playlists.map((p) => p.name), ['Default Setlist', 'Two']);
      expect(r.songCount, 5);
    });
  });
}
