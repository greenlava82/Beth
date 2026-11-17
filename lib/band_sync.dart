// Bluetooth LE transport for band sync (see band_sync_protocol.dart for the
// wire format).
//
// Leader: re-advertises the live state as a 128-bit "service UUID" whenever
// it changes (and at least every second as a heartbeat), and runs a small
// GATT service so a joining follower can read the playlist and song names
// once. Followers scan continuously, without connecting, and connect only to
// read those details on joining or when the leader's details version changes.
//
// No advertised name is used: on Android that would rename the phone's
// Bluetooth adapter, and it doesn't fit next to a 128-bit UUID anyway.

import 'dart:async';
import 'dart:math' as math;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'band_sync_icon.dart';
import 'band_sync_protocol.dart';

/// What the leader is broadcasting right now; [BandSyncState.sessionId] and
/// [BandSyncState.sequence] are filled in by [BandSyncLeader].
typedef BandSyncSnapshot = ({BandSyncState state, BandSyncDetails details});

final UUID _serviceUuid = UUID.fromString(bandSyncServiceUuid);
final UUID _detailsUuid = UUID.fromString(bandSyncDetailsUuid);

/// Waits until Bluetooth is on and the app may use it, asking for
/// permission first where the platform needs it. Returns an error message,
/// or null when ready.
Future<String?> _ready(BluetoothLowEnergyManager manager) async {
  Future<void> waitWhile(BluetoothLowEnergyState s, Duration limit) async {
    if (manager.state != s) return;
    await manager.stateChanged
        .firstWhere((e) => e.state != s)
        .timeout(
          limit,
          onTimeout: () {
            return BluetoothLowEnergyStateChangedEventArgs(manager.state);
          },
        );
  }

  // The real state arrives shortly after the manager is created; on Darwin
  // the first use also shows the Bluetooth permission prompt, so allow time
  // for the user to answer it.
  await waitWhile(BluetoothLowEnergyState.unknown, const Duration(seconds: 30));
  if (manager.state == BluetoothLowEnergyState.unauthorized &&
      defaultTargetPlatform == TargetPlatform.android) {
    // authorize() returns once the user answers, but the plugin only
    // refreshes its state when the app resumes after the dialog.
    if (await manager.authorize()) {
      await waitWhile(
        BluetoothLowEnergyState.unauthorized,
        const Duration(seconds: 3),
      );
    }
  }
  return switch (manager.state) {
    BluetoothLowEnergyState.poweredOn => null,
    BluetoothLowEnergyState.poweredOff => 'Bluetooth is off',
    BluetoothLowEnergyState.unauthorized => 'Bluetooth permission is needed',
    BluetoothLowEnergyState.unsupported =>
      'This device can’t use Bluetooth LE for band sync',
    BluetoothLowEnergyState.unknown => 'Bluetooth isn’t ready',
  };
}

/// Broadcasts this phone's state to followers.
class BandSyncLeader extends ChangeNotifier {
  BandSyncLeader(this._snapshot);

  /// Called a few times a second for the current state to broadcast.
  final BandSyncSnapshot Function() _snapshot;

  static const Duration _poll = Duration(milliseconds: 250);

  PeripheralManager? _manager;
  StreamSubscription<GATTCharacteristicReadRequestedEventArgs>? _readSub;
  Timer? _timer;
  bool _busy = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  BandSyncState? _sent;
  Uint8List _detailsBytes = Uint8List(0);
  final Set<String> _joined = {};

  bool _active = false;
  bool get isActive => _active;

  String? _error;
  String? get error => _error;

  int _sessionId = 0;
  String get code => sessionCode(_sessionId);
  BandSyncIcon get icon => BandSyncIcon.forSession(_sessionId);

  /// Distinct followers that have read the details since starting (a
  /// connectionless follower is otherwise invisible to the leader).
  int get joinedCount => _joined.length;

  /// Start broadcasting, with a fresh session id that shows [icon] (the
  /// band's chosen icon) or a random one. Returns an error message, or null
  /// on success.
  Future<String?> start({BandSyncIcon? icon}) async {
    if (_active) return null;
    final manager = _manager ??= PeripheralManager();
    final problem = await _ready(manager);
    if (problem != null) {
      _error = problem;
      notifyListeners();
      return problem;
    }
    _sessionId = icon != null && icon.isValid
        ? sessionIdForIcon(icon)
        : math.Random().nextInt(0x10000);
    _joined.clear();
    _sent = null;
    _error = null;
    try {
      await manager.removeAllServices();
      await manager.addService(
        GATTService(
          uuid: _serviceUuid,
          isPrimary: true,
          includedServices: const [],
          characteristics: [
            GATTCharacteristic.mutable(
              uuid: _detailsUuid,
              properties: const [GATTCharacteristicProperty.read],
              permissions: const [GATTCharacteristicPermission.read],
              descriptors: const [],
            ),
          ],
        ),
      );
    } catch (e) {
      _error = 'Couldn’t start band sync: $e';
      notifyListeners();
      return _error;
    }
    _readSub = manager.characteristicReadRequested.listen(_onRead);
    _active = true;
    _timer = Timer.periodic(_poll, (_) => _tick());
    notifyListeners();
    await _tick();
    return null;
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _timer?.cancel();
    _timer = null;
    await _readSub?.cancel();
    _readSub = null;
    final manager = _manager;
    if (manager != null) {
      try {
        await manager.stopAdvertising();
        await manager.removeAllServices();
      } catch (_) {
        // Bluetooth may already be off.
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  Future<void> _onRead(GATTCharacteristicReadRequestedEventArgs e) async {
    final manager = _manager;
    if (manager == null) return;
    // Long reads arrive in chunks, each asking from an offset.
    final offset = e.request.offset.clamp(0, _detailsBytes.length);
    if (offset == 0) _joined.add(e.central.uuid.toString());
    try {
      await manager.respondReadRequestWithValue(
        e.request,
        value: Uint8List.sublistView(_detailsBytes, offset),
      );
    } catch (_) {
      // The follower went away mid-read; it will retry.
    }
    if (offset == 0) notifyListeners();
  }

  Future<void> _tick() async {
    if (!_active || _busy) return;
    final snap = _snapshot();
    _detailsBytes = snap.details.toBytes();
    final previous = _sent;
    final now = DateTime.now();
    final state = BandSyncState(
      sessionId: _sessionId,
      sequence: previous?.sequence ?? 0,
      metronomePlaying: snap.state.metronomePlaying,
      freeRunning: snap.state.freeRunning,
      drift: snap.state.drift,
      rushing: snap.state.rushing,
      songIndex: snap.state.songIndex,
      targetBpm: snap.state.targetBpm,
      detectedBpm: snap.state.detectedBpm,
      confidence: snap.state.confidence,
      detailsVersion: snap.state.detailsVersion,
    );
    final changed = previous == null || !state.sameContentAs(previous);
    final heartbeatDue =
        now.difference(_lastSent) >= BandSyncFreshness.heartbeat;
    if (!changed && !heartbeatDue) return;

    final next = state.copyWith(
      sequence: previous == null ? 0 : (previous.sequence + 1) & 0xFF,
    );
    _busy = true;
    try {
      final manager = _manager!;
      // Advertising data can't be changed in place: restart it.
      if (previous != null) await manager.stopAdvertising();
      await manager.startAdvertising(
        Advertisement(serviceUUIDs: [UUID(encodeBandSyncPayload(next))]),
      );
      _sent = next;
      _lastSent = now;
      if (_error != null) {
        _error = null;
        notifyListeners();
      }
    } catch (e) {
      _error = 'Broadcast failed: $e';
      notifyListeners();
    } finally {
      _busy = false;
    }
  }
}

/// A leader heard while scanning.
class BandSyncLeaderSighting {
  BandSyncLeaderSighting(this.peripheral, this.state, this.rssi, this.seen);

  Peripheral peripheral;
  BandSyncState state;
  int rssi;
  DateTime seen;
}

/// Listens for leaders and mirrors one of them.
class BandSyncFollower extends ChangeNotifier {
  CentralManager? _manager;
  StreamSubscription<DiscoveredEventArgs>? _discoverSub;
  Timer? _restartTimer;
  Timer? _clockTimer;

  // Android quietly downgrades scans that run longer than 30 minutes, so
  // restart well before that.
  static const Duration _scanRestart = Duration(minutes: 10);
  // Sightings older than this drop out of the "nearby leaders" list.
  static const Duration _forgetAfter = Duration(seconds: 15);

  final Map<int, BandSyncLeaderSighting> _leaders = {};

  bool _scanning = false;
  bool get isScanning => _scanning;

  String? _error;
  String? get error => _error;

  /// Leaders heard recently, strongest signal first.
  List<BandSyncLeaderSighting> get leaders {
    final cutoff = DateTime.now().subtract(_forgetAfter);
    return _leaders.values.where((l) => l.seen.isAfter(cutoff)).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  int? _followedSession;
  int? get followedSession => _followedSession;

  /// The followed leader's latest state, or null before it's been heard.
  BandSyncState? get state =>
      _followedSession == null ? null : _leaders[_followedSession]?.state;

  BandSyncDetails? _details;
  int? _detailsVersion;
  BandSyncDetails? get details => _details;
  bool _readingDetails = false;
  bool get isReadingDetails => _readingDetails;
  String? _detailsError;
  String? get detailsError => _detailsError;

  final BandSyncFreshness freshness = BandSyncFreshness();
  BandSyncLink get link => freshness.linkAt(DateTime.now());

  /// Start listening for leaders. Returns an error message, or null.
  Future<String?> start() async {
    if (_scanning) return null;
    final manager = _manager ??= CentralManager();
    final problem = await _ready(manager);
    if (problem != null) {
      _error = problem;
      notifyListeners();
      return problem;
    }
    _error = null;
    _discoverSub = manager.discovered.listen(_onDiscovered);
    try {
      await manager.startDiscovery();
    } catch (e) {
      _error = 'Couldn’t scan: $e';
      notifyListeners();
      return _error;
    }
    _scanning = true;
    _restartTimer = Timer.periodic(_scanRestart, (_) => _restartScan());
    // Ticks the staleness display and the nearby list.
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
    return null;
  }

  Future<void> stop() async {
    _restartTimer?.cancel();
    _clockTimer?.cancel();
    await _discoverSub?.cancel();
    _discoverSub = null;
    if (_scanning) {
      _scanning = false;
      try {
        await _manager?.stopDiscovery();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  Future<void> _restartScan() async {
    final manager = _manager;
    if (manager == null || !_scanning) return;
    try {
      await manager.stopDiscovery();
      await manager.startDiscovery();
    } catch (e) {
      _error = 'Scan restart failed: $e';
      notifyListeners();
    }
  }

  /// Mirror the leader with [sessionId] (from [leaders]).
  void follow(int sessionId) {
    _followedSession = sessionId;
    _details = null;
    _detailsVersion = null;
    _detailsError = null;
    freshness.reset();
    final s = _leaders[sessionId];
    if (s != null) {
      freshness.heard(s.state, s.seen);
      _readDetails();
    }
    notifyListeners();
  }

  void unfollow() {
    _followedSession = null;
    _details = null;
    _detailsVersion = null;
    freshness.reset();
    notifyListeners();
  }

  void _onDiscovered(DiscoveredEventArgs e) {
    final state = findBandSyncState(
      e.advertisement.serviceUUIDs.map((u) => u.toString()),
    );
    if (state == null) return;
    final now = DateTime.now();
    final known = _leaders[state.sessionId];
    final isNew = known == null || known.state.sequence != state.sequence;
    if (known == null) {
      _leaders[state.sessionId] = BandSyncLeaderSighting(
        e.peripheral,
        state,
        e.rssi,
        now,
      );
    } else {
      // Track by session, not device: the leader's Bluetooth address can
      // rotate during a set.
      known
        ..peripheral = e.peripheral
        ..state = state
        ..rssi = e.rssi
        ..seen = now;
    }
    if (state.sessionId == _followedSession) {
      freshness.heard(state, now);
      if (state.detailsVersion != _detailsVersion) _readDetails();
    }
    // The radio repeats each advertisement many times a second; only
    // rebuild for news.
    if (isNew) notifyListeners();
  }

  Future<void> _readDetails() async {
    final session = _followedSession;
    final sighting = session == null ? null : _leaders[session];
    final manager = _manager;
    if (_readingDetails || sighting == null || manager == null) return;
    final wanted = sighting.state.detailsVersion;
    _readingDetails = true;
    notifyListeners();
    final peripheral = sighting.peripheral;
    try {
      await manager.connect(peripheral).timeout(const Duration(seconds: 10));
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Room for a long setlist in one go (Darwin negotiates itself).
        try {
          await manager.requestMTU(peripheral, mtu: 517);
        } catch (_) {}
      }
      final services = await manager.discoverGATT(peripheral);
      final characteristic = services
          .where((s) => s.uuid == _serviceUuid)
          .expand((s) => s.characteristics)
          .firstWhere((c) => c.uuid == _detailsUuid);
      final bytes = await manager.readCharacteristic(
        peripheral,
        characteristic,
      );
      final details = BandSyncDetails.fromBytes(bytes);
      if (details == null) throw const FormatException('unreadable details');
      if (_followedSession == session) {
        _details = details;
        // Use the version the leader advertised when we started reading, so
        // a change during the read triggers another one.
        _detailsVersion = wanted;
        _detailsError = null;
      }
    } catch (e) {
      _detailsError = 'Couldn’t read song names ($e)';
    } finally {
      try {
        await manager.disconnect(peripheral);
      } catch (_) {}
      _readingDetails = false;
      notifyListeners();
    }
    // Retry after a failure, or if the leader changed during the read.
    final latest = _leaders[session]?.state.detailsVersion;
    if (_followedSession == session && latest != _detailsVersion) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_followedSession == session) _readDetails();
    }
  }
}
