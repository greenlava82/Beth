import 'package:flutter_test/flutter_test.dart';
import 'package:beth/playlist.dart';

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
    test('older saves with time signature and notes still load', () {
      final p = decodePlaylists('[{"name":"Old","items":[{"name":"A","bpm":100,'
          '"timeSignature":"3/4","notes":"Key of D","durationSeconds":245}]}]')!
          .single;
      final song = p.items.single;
      expect(song.name, 'A');
      expect(song.bpm, 100);
      expect(song.durationSeconds, 245);
      // The dropped fields aren't written back.
      expect(song.toJson().keys, unorderedEquals(['name', 'bpm', 'durationSeconds']));
    });

    test('duration round-trips through JSON and is optional', () {
      final back = decodePlaylists(encodePlaylists([
        Playlist('P', [SetlistItem('A', 150, durationSeconds: 245), SetlistItem('B', 90)])
      ]))!.single.items;
      expect(back[0].durationSeconds, 245);
      expect(back[1].durationSeconds, isNull);
      expect(back[1].toJson().containsKey('durationSeconds'), isFalse);
    });

    test('copy keeps the duration', () {
      final b = SetlistItem('a', 90, durationSeconds: 60).copy();
      expect([b.name, b.bpm, b.durationSeconds], ['a', 90, 60]);
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
