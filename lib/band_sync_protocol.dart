/// Wire format for band sync: one leader phone broadcasts the live state to
/// any number of followers over Bluetooth LE, without connections.
///
/// iOS only lets an app advertise a local name and a list of service UUIDs
/// (no manufacturer or service data), so the live state is packed into the
/// 16 bytes of a 128-bit "service UUID" that the leader re-advertises whenever
/// it changes. Details that don't fit (the playlist name and song titles) are
/// read once over a GATT connection when a follower joins, and again only
/// when [BandSyncState.detailsVersion] changes.
///
/// Payload layout (byte offsets):
///
/// | 0–1   | magic `5C BE`                                   |
/// | 2     | protocol version ([bandSyncProtocolVersion])    |
/// | 3–4   | session id (identifies one leader's broadcast)  |
/// | 5     | sequence, bumped on every change and heartbeat  |
/// | 6     | flags (see [_flagPlaying] etc.) and drift level |
/// | 7     | song index, 255 = none                          |
/// | 8–9   | target BPM × 10, 0 = none                       |
/// | 10–11 | detected BPM × 10, 0 = none                     |
/// | 12    | detection confidence × 255                      |
/// | 13–14 | details version                                 |
/// | 15    | check byte                                      |
///
/// Pure Dart (no Flutter imports) so it stays fast to unit-test.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'tempo_drift.dart';

const int bandSyncProtocolVersion = 1;
const int _magic0 = 0x5C;
const int _magic1 = 0xBE;
const int _payloadLength = 16;

const int _flagPlaying = 0x01;
const int _flagFreeRunning = 0x02;
const int _flagRushing = 0x04;
const int _driftShift = 4; // two bits: 0 none, 1 on, 2 drifting, 3 off

/// GATT service the leader runs for followers joining (fixed, unlike the
/// advertised payload UUID).
const String bandSyncServiceUuid = '5cbe0001-7a3e-4b8e-9c61-2f0d5b9e4a10';

/// Read-only characteristic holding [BandSyncDetails] as UTF-8 JSON.
const String bandSyncDetailsUuid = '5cbe0002-7a3e-4b8e-9c61-2f0d5b9e4a10';

/// The live state one leader broadcasts.
class BandSyncState {
  const BandSyncState({
    required this.sessionId,
    this.sequence = 0,
    this.metronomePlaying = false,
    this.freeRunning = false,
    this.drift,
    this.rushing = false,
    this.songIndex,
    this.targetBpm,
    this.detectedBpm,
    this.confidence = 0,
    this.detailsVersion = 0,
  });

  /// 0–65535, chosen at random when the leader starts broadcasting.
  final int sessionId;

  /// 0–255, wraps. Followers treat an unchanged sequence as "no news".
  final int sequence;
  final bool metronomePlaying;
  final bool freeRunning;

  /// The leader's drift level, so every screen shows the same colour.
  final DriftLevel? drift;
  final bool rushing;

  /// Index into [BandSyncDetails.songs], or null (free-running, no songs).
  final int? songIndex;
  final double? targetBpm;
  final double? detectedBpm;

  /// 0..1.
  final double confidence;

  /// Changes whenever [BandSyncDetails] change (see [detailsVersionOf]).
  final int detailsVersion;

  /// The session id as four hex digits, shown on both screens so the band
  /// can check they joined the right leader.
  String get code => sessionCode(sessionId);

  BandSyncState copyWith({int? sequence}) => BandSyncState(
    sessionId: sessionId,
    sequence: sequence ?? this.sequence,
    metronomePlaying: metronomePlaying,
    freeRunning: freeRunning,
    drift: drift,
    rushing: rushing,
    songIndex: songIndex,
    targetBpm: targetBpm,
    detectedBpm: detectedBpm,
    confidence: confidence,
    detailsVersion: detailsVersion,
  );

  /// True if [other] carries the same information, ignoring [sequence].
  /// BPMs and confidence compare at their wire precision.
  bool sameContentAs(BandSyncState other) {
    final a = encodeBandSyncPayload(this);
    final b = encodeBandSyncPayload(other.copyWith(sequence: sequence));
    for (var i = 0; i < _payloadLength; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'BandSyncState($code #$sequence song=$songIndex '
      'target=$targetBpm heard=$detectedBpm conf=${confidence.toStringAsFixed(2)} '
      'drift=$drift playing=$metronomePlaying free=$freeRunning '
      'details=$detailsVersion)';
}

String sessionCode(int sessionId) =>
    sessionId.toRadixString(16).padLeft(4, '0').toUpperCase();

int _bpmToWire(double? bpm) {
  if (bpm == null || bpm.isNaN || bpm <= 0) return 0;
  return (bpm * 10).round().clamp(1, 0xFFFF);
}

double? _bpmFromWire(int v) => v == 0 ? null : v / 10;

int _check(List<int> b) {
  var x = 0xA5;
  for (var i = 0; i < _payloadLength - 1; i++) {
    x ^= b[i];
  }
  return x;
}

Uint8List encodeBandSyncPayload(BandSyncState s) {
  final b = Uint8List(_payloadLength);
  b[0] = _magic0;
  b[1] = _magic1;
  b[2] = bandSyncProtocolVersion;
  b[3] = (s.sessionId >> 8) & 0xFF;
  b[4] = s.sessionId & 0xFF;
  b[5] = s.sequence & 0xFF;
  final drift = switch (s.drift) {
    null => 0,
    DriftLevel.onTempo => 1,
    DriftLevel.drifting => 2,
    DriftLevel.off => 3,
  };
  b[6] =
      (s.metronomePlaying ? _flagPlaying : 0) |
      (s.freeRunning ? _flagFreeRunning : 0) |
      (s.rushing ? _flagRushing : 0) |
      (drift << _driftShift);
  final song = s.songIndex;
  b[7] = (song == null || song < 0 || song > 254) ? 255 : song;
  final target = _bpmToWire(s.targetBpm);
  b[8] = target >> 8;
  b[9] = target & 0xFF;
  final heard = _bpmToWire(s.detectedBpm);
  b[10] = heard >> 8;
  b[11] = heard & 0xFF;
  b[12] = (s.confidence.clamp(0.0, 1.0) * 255).round();
  b[13] = (s.detailsVersion >> 8) & 0xFF;
  b[14] = s.detailsVersion & 0xFF;
  b[15] = _check(b);
  return b;
}

/// Null for anything that isn't a valid payload of a version we understand
/// (other devices' service UUIDs, corrupted data, a newer protocol).
BandSyncState? decodeBandSyncPayload(List<int> b) {
  if (b.length != _payloadLength) return null;
  if (b[0] != _magic0 || b[1] != _magic1) return null;
  if (b[2] != bandSyncProtocolVersion) return null;
  if (b[15] != _check(b)) return null;
  final flags = b[6];
  final drift = switch ((flags >> _driftShift) & 0x3) {
    1 => DriftLevel.onTempo,
    2 => DriftLevel.drifting,
    3 => DriftLevel.off,
    _ => null,
  };
  return BandSyncState(
    sessionId: (b[3] << 8) | b[4],
    sequence: b[5],
    metronomePlaying: flags & _flagPlaying != 0,
    freeRunning: flags & _flagFreeRunning != 0,
    rushing: flags & _flagRushing != 0,
    drift: drift,
    songIndex: b[7] == 255 ? null : b[7],
    targetBpm: _bpmFromWire((b[8] << 8) | b[9]),
    detectedBpm: _bpmFromWire((b[10] << 8) | b[11]),
    confidence: b[12] / 255,
    detailsVersion: (b[13] << 8) | b[14],
  );
}

/// The payload as a UUID string (8-4-4-4-12 hex, lower case), byte 0 first.
String bandSyncPayloadToUuid(List<int> bytes) {
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The 16 bytes of a 128-bit UUID string, or null if it isn't one (16- and
/// 32-bit short UUIDs, malformed strings).
List<int>? bandSyncUuidToPayload(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) return null;
  final out = <int>[];
  for (var i = 0; i < 32; i += 2) {
    final v = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

String encodeBandSyncUuid(BandSyncState s) =>
    bandSyncPayloadToUuid(encodeBandSyncPayload(s));

BandSyncState? decodeBandSyncUuid(String uuid) {
  final bytes = bandSyncUuidToPayload(uuid);
  return bytes == null ? null : decodeBandSyncPayload(bytes);
}

/// Finds a band sync payload among a device's advertised service UUIDs.
BandSyncState? findBandSyncState(Iterable<String> serviceUuids) {
  for (final u in serviceUuids) {
    final s = decodeBandSyncUuid(u);
    if (s != null) return s;
  }
  return null;
}

/// What a follower reads once on joining: names for the numbers in
/// [BandSyncState].
class BandSyncDetails {
  const BandSyncDetails({required this.playlistName, required this.songs});

  final String playlistName;

  /// Song titles in setlist order ([BandSyncState.songIndex] indexes this).
  final List<String> songs;

  String? songAt(int? index) =>
      (index == null || index < 0 || index >= songs.length)
      ? null
      : songs[index];

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': bandSyncProtocolVersion,
        'playlist': playlistName,
        'songs': songs,
      }),
    ),
  );

  /// Tolerant: missing or odd fields become empty values; null only for
  /// data that isn't a JSON object at all.
  static BandSyncDetails? fromBytes(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (json is! Map) return null;
      final songs = json['songs'];
      return BandSyncDetails(
        playlistName: json['playlist'] is String ? json['playlist'] : '',
        songs: songs is List ? [for (final s in songs) '$s'] : const [],
      );
    } on FormatException {
      return null;
    }
  }
}

/// A 16-bit fingerprint of [details] (FNV-1a over its bytes), so followers
/// can tell from the broadcast when to read the details again.
int detailsVersionOf(BandSyncDetails details) {
  var h = 0x811C9DC5;
  for (final b in details.toBytes()) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return (h ^ (h >> 16)) & 0xFFFF;
}

/// How current a follower's view of the leader is.
enum BandSyncLink {
  /// Fresh data within [BandSyncFreshness.staleAfter].
  live,

  /// Nothing new for a while: the leader may have frozen or moved away.
  stale,

  /// Nothing new for longer than [BandSyncFreshness.lostAfter].
  lost,
}

/// Tracks when a follower last heard *new* data from its leader.
///
/// The radio keeps repeating the last advertisement, so a frozen leader
/// still "sounds" alive; only a change in [BandSyncState.sequence] counts as
/// news. The leader bumps the sequence at least every [heartbeat].
class BandSyncFreshness {
  BandSyncFreshness({
    this.staleAfter = const Duration(seconds: 4),
    this.lostAfter = const Duration(seconds: 12),
  });

  /// How often a leader bumps the sequence when nothing else changes.
  static const Duration heartbeat = Duration(seconds: 1);

  final Duration staleAfter;
  final Duration lostAfter;

  int? _lastSequence;
  DateTime? _lastNews;

  DateTime? get lastNews => _lastNews;

  /// Record a received state. Returns true if it was news.
  bool heard(BandSyncState s, DateTime at) {
    if (s.sequence == _lastSequence) return false;
    _lastSequence = s.sequence;
    _lastNews = at;
    return true;
  }

  BandSyncLink linkAt(DateTime now) {
    final last = _lastNews;
    if (last == null) return BandSyncLink.lost;
    final age = now.difference(last);
    if (age > lostAfter) return BandSyncLink.lost;
    if (age > staleAfter) return BandSyncLink.stale;
    return BandSyncLink.live;
  }

  void reset() {
    _lastSequence = null;
    _lastNews = null;
  }
}
