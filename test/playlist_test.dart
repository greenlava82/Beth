import 'package:flutter_test/flutter_test.dart';
import 'package:scbeatwiz/playlist.dart';

void main() {
  test('round-trips through JSON', () {
    final original = defaultPlaylists();
    final decoded = decodePlaylists(encodePlaylists(original))!;
    expect(decoded.length, 1);
    expect(decoded[0].name, 'Default Setlist');
    expect(decoded[0].items.map((s) => s.bpm), [80, 120, 160, 105]);
    expect(decoded[0].items[1].name, 'Song 2 (Upbeat)');
  });

  test('reads data saved by earlier versions', () {
    const v1 = '[{"name":"Gig","items":[{"name":"Intro","bpm":96}]}]';
    final p = decodePlaylists(v1)!.single;
    expect(p.name, 'Gig');
    expect(p.items.single.name, 'Intro');
    expect(p.items.single.bpm, 96);
  });

  test('fills in missing fields', () {
    final p = decodePlaylists('[{"items":[{"bpm":101.6},{}]}]')!.single;
    expect(p.name, 'Untitled Playlist');
    expect(p.items[0].name, 'Unnamed Song');
    expect(p.items[0].bpm, 102);
    expect(p.items[1].bpm, 120);
  });

  test('returns null for missing, empty or corrupt data', () {
    expect(decodePlaylists(null), isNull);
    expect(decodePlaylists('[]'), isNull);
    expect(decodePlaylists('not json'), isNull);
    expect(decodePlaylists('{"name":"x"}'), isNull);
  });

  test('copy is deep', () {
    final a = defaultPlaylists().first;
    final b = a.copy(name: 'Copy');
    b.items.first.bpm = 999;
    b.items.removeLast();
    expect(b.name, 'Copy');
    expect(a.items.first.bpm, 80);
    expect(a.items.length, 4);
  });

  group('song details', () {
    test('default to 4/4, no notes, no duration', () {
      final p = decodePlaylists(
          '[{"name":"Old","items":[{"name":"A","bpm":100}]}]')!.single;
      final song = p.items.single;
      expect(song.timeSignature, '4/4');
      expect(song.beatsPerBar, 4);
      expect(song.notes, '');
      expect(song.durationSeconds, isNull);
    });

    test('round-trip through JSON', () {
      final song = SetlistItem('Waltz', 150,
          timeSignature: '3/4', notes: 'Key of D\nPiano starts', durationSeconds: 245);
      final back = decodePlaylists(encodePlaylists([
        Playlist('P', [song])
      ]))!.single.items.single;
      expect(back.timeSignature, '3/4');
      expect(back.beatsPerBar, 3);
      expect(back.notes, 'Key of D\nPiano starts');
      expect(back.durationSeconds, 245);
    });

    test('unknown time signature falls back to 4/4', () {
      final song = SetlistItem.fromJson(
          {'name': 'X', 'bpm': 90, 'timeSignature': '11/3'});
      expect(song.timeSignature, '4/4');
    });

    test('beatsPerBar follows the top number', () {
      expect(SetlistItem('a', 1, timeSignature: '6/8').beatsPerBar, 6);
      expect(SetlistItem('a', 1, timeSignature: '12/8').beatsPerBar, 12);
    });

    test('copy keeps details', () {
      final a = SetlistItem('a', 90,
          timeSignature: '7/8', notes: 'n', durationSeconds: 60);
      final b = a.copy();
      expect([b.timeSignature, b.notes, b.durationSeconds], ['7/8', 'n', 60]);
    });
  });

  group('durations', () {
    test('format', () {
      expect(formatDuration(185), '3:05');
      expect(formatDuration(59), '0:59');
      expect(formatDuration(3600), '60:00');
    });

    test('parse', () {
      expect(parseDuration('3:05'), 185);
      expect(parseDuration(' 4 '), 240);
      expect(parseDuration('0:45'), 45);
      expect(parseDuration(''), isNull);
      expect(parseDuration('3:75'), isNull);
      expect(parseDuration('abc'), isNull);
      expect(parseDuration('0'), isNull);
    });

    test('playlist total counts only known durations', () {
      final p = Playlist('P', [
        SetlistItem('a', 1, durationSeconds: 200),
        SetlistItem('b', 1),
        SetlistItem('c', 1, durationSeconds: 100),
      ]);
      final d = playlistDuration(p);
      expect(d.seconds, 300);
      expect(d.known, 2);
    });
  });
}
