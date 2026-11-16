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
}
