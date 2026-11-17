import 'package:flutter_test/flutter_test.dart';
import 'package:beth/band_sync_protocol.dart';
import 'package:beth/tempo_drift.dart';

void main() {
  const full = BandSyncState(
    sessionId: 0x4F2A,
    sequence: 200,
    metronomePlaying: true,
    drift: DriftLevel.drifting,
    rushing: true,
    songIndex: 3,
    targetBpm: 118,
    detectedBpm: 121.4,
    confidence: 0.62,
    detailsVersion: 0xBEEF,
  );

  group('payload', () {
    test('is 16 bytes and round-trips', () {
      final bytes = encodeBandSyncPayload(full);
      expect(bytes, hasLength(16));
      final back = decodeBandSyncPayload(bytes)!;
      expect(back.sessionId, 0x4F2A);
      expect(back.code, '4F2A');
      expect(back.sequence, 200);
      expect(back.metronomePlaying, isTrue);
      expect(back.freeRunning, isFalse);
      expect(back.drift, DriftLevel.drifting);
      expect(back.rushing, isTrue);
      expect(back.songIndex, 3);
      expect(back.targetBpm, 118);
      expect(back.detectedBpm, closeTo(121.4, 1e-9));
      expect(back.confidence, closeTo(0.62, 1 / 255));
      expect(back.detailsVersion, 0xBEEF);
    });

    test('empty state: no song, no target, no reading', () {
      const s = BandSyncState(sessionId: 1, freeRunning: true);
      final back = decodeBandSyncPayload(encodeBandSyncPayload(s))!;
      expect(back.songIndex, isNull);
      expect(back.targetBpm, isNull);
      expect(back.detectedBpm, isNull);
      expect(back.drift, isNull);
      expect(back.freeRunning, isTrue);
    });

    test('every drift level survives', () {
      for (final d in [null, ...DriftLevel.values]) {
        final s = BandSyncState(sessionId: 7, drift: d);
        expect(decodeBandSyncPayload(encodeBandSyncPayload(s))!.drift, d);
      }
    });

    test('out-of-range values are clamped, not wrapped', () {
      const s = BandSyncState(
        sessionId: 9,
        songIndex: 300,
        confidence: 1.7,
        detectedBpm: -5,
      );
      final back = decodeBandSyncPayload(encodeBandSyncPayload(s))!;
      expect(back.songIndex, isNull);
      expect(back.confidence, 1);
      expect(back.detectedBpm, isNull);
    });

    test('rejects other devices, corruption and newer versions', () {
      final good = encodeBandSyncPayload(full);
      expect(decodeBandSyncPayload(good.sublist(0, 15)), isNull);
      final wrongMagic = List<int>.of(good)..[0] = 0x00;
      expect(decodeBandSyncPayload(wrongMagic), isNull);
      final flipped = List<int>.of(good)..[10] ^= 0x01;
      expect(decodeBandSyncPayload(flipped), isNull);
      final newer = List<int>.of(good)..[2] = bandSyncProtocolVersion + 1;
      expect(decodeBandSyncPayload(newer), isNull);
    });
  });

  group('UUID form', () {
    test('round-trips through a UUID string', () {
      final uuid = encodeBandSyncUuid(full);
      expect(
        uuid,
        matches(
          RegExp(
            r'^5cbe01[0-9a-f]{2}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(decodeBandSyncUuid(uuid)!.detectedBpm, closeTo(121.4, 1e-9));
      // Platforms may report it upper case.
      expect(decodeBandSyncUuid(uuid.toUpperCase())!.songIndex, 3);
    });

    test('short and foreign UUIDs are ignored', () {
      expect(decodeBandSyncUuid('180d'), isNull);
      expect(
        decodeBandSyncUuid('0000180d-0000-1000-8000-00805f9b34fb'),
        isNull,
      );
      expect(decodeBandSyncUuid(bandSyncServiceUuid), isNull);
      expect(decodeBandSyncUuid('not-a-uuid'), isNull);
    });

    test('finds the payload among other advertised services', () {
      final s = findBandSyncState(['180d', encodeBandSyncUuid(full)]);
      expect(s?.sessionId, 0x4F2A);
      expect(findBandSyncState(['180d']), isNull);
    });
  });

  test('sameContentAs ignores the sequence only', () {
    expect(full.sameContentAs(full.copyWith(sequence: 5)), isTrue);
    const other = BandSyncState(sessionId: 0x4F2A, sequence: 200);
    expect(full.sameContentAs(other), isFalse);
    // Below wire precision counts as the same.
    const a = BandSyncState(sessionId: 1, detectedBpm: 120.01);
    const b = BandSyncState(sessionId: 1, detectedBpm: 120.04);
    expect(a.sameContentAs(b), isTrue);
  });

  group('details', () {
    const details = BandSyncDetails(
      playlistName: 'Friday Gig',
      songs: ['Valerie', 'Ça va'],
    );

    test('round-trip, including non-ASCII titles', () {
      final back = BandSyncDetails.fromBytes(details.toBytes())!;
      expect(back.playlistName, 'Friday Gig');
      expect(back.songs, ['Valerie', 'Ça va']);
      expect(back.songAt(1), 'Ça va');
      expect(back.songAt(2), isNull);
      expect(back.songAt(null), isNull);
    });

    test('tolerant of partial data, null for garbage', () {
      final partial = BandSyncDetails.fromBytes('{"playlist":"X"}'.codeUnits)!;
      expect(partial.playlistName, 'X');
      expect(partial.songs, isEmpty);
      expect(BandSyncDetails.fromBytes('nope'.codeUnits), isNull);
      expect(BandSyncDetails.fromBytes('[1,2]'.codeUnits), isNull);
    });

    test('version changes with the content and is stable', () {
      final v = detailsVersionOf(details);
      expect(detailsVersionOf(details), v);
      const renamed = BandSyncDetails(
        playlistName: 'Friday Gig',
        songs: ['Valerie', 'Ca va'],
      );
      expect(detailsVersionOf(renamed), isNot(v));
      expect(v, inInclusiveRange(0, 0xFFFF));
    });
  });

  group('freshness', () {
    final t0 = DateTime(2026, 11, 17, 20);

    test('lost until anything is heard', () {
      expect(BandSyncFreshness().linkAt(t0), BandSyncLink.lost);
    });

    test('only a new sequence counts as news', () {
      final f = BandSyncFreshness();
      expect(f.heard(full, t0), isTrue);
      expect(f.linkAt(t0.add(const Duration(seconds: 3))), BandSyncLink.live);
      // The same advertisement repeated by the radio isn't news…
      expect(f.heard(full, t0.add(const Duration(seconds: 3))), isFalse);
      expect(f.linkAt(t0.add(const Duration(seconds: 5))), BandSyncLink.stale);
      expect(f.linkAt(t0.add(const Duration(seconds: 13))), BandSyncLink.lost);
      // …but the next heartbeat is.
      final later = t0.add(const Duration(seconds: 14));
      expect(f.heard(full.copyWith(sequence: 201), later), isTrue);
      expect(f.linkAt(later), BandSyncLink.live);
    });

    test('reset forgets the leader', () {
      final f = BandSyncFreshness()..heard(full, t0);
      f.reset();
      expect(f.linkAt(t0), BandSyncLink.lost);
      expect(f.heard(full, t0), isTrue);
    });
  });
}
