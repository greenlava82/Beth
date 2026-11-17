import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'band_sync.dart';
import 'band_sync_protocol.dart';
import 'tempo_drift.dart';

/// Follower view: pick a nearby leader, then mirror its song, target and
/// detected tempo. Followers don't listen to the mic themselves.
class BandSyncFollowerScreen extends StatefulWidget {
  const BandSyncFollowerScreen({super.key});

  @override
  State<BandSyncFollowerScreen> createState() => _BandSyncFollowerScreenState();
}

class _BandSyncFollowerScreenState extends State<BandSyncFollowerScreen> {
  final BandSyncFollower _follower = BandSyncFollower();

  @override
  void initState() {
    super.initState();
    _follower.addListener(_changed);
    _follower.start();
    // Mirroring a leader for a whole set: keep the screen on.
    WakelockPlus.enable();
  }

  void _changed() {
    if (!mounted) return;
    // Join automatically when there's exactly one band around.
    final leaders = _follower.leaders;
    if (_follower.followedSession == null && leaders.length == 1) {
      _follower.follow(leaders.single.state.sessionId);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _follower.removeListener(_changed);
    _follower.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final following = _follower.followedSession;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          following == null
              ? 'Follow a leader'
              : 'Following ${sessionCode(following)}',
        ),
        actions: [
          if (following != null)
            IconButton(
              tooltip: 'Choose another leader',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _follower.unfollow,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _follower.error != null
            ? _message(Icons.bluetooth_disabled, _follower.error!)
            : following == null
            ? _buildLeaderList()
            : _buildMirror(context),
      ),
    );
  }

  Widget _message(IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );

  Widget _buildLeaderList() {
    final leaders = _follower.leaders;
    if (leaders.isEmpty) {
      return _message(
        Icons.bluetooth_searching,
        'Looking for a leader…\n\nOn the leader’s phone, tap the band icon '
        'and choose “Lead the band”.',
      );
    }
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Nearby leaders — check the code matches the '
            'leader’s screen',
          ),
        ),
        for (final l in leaders)
          ListTile(
            leading: const Icon(Icons.podcasts),
            title: Text('Leader ${l.state.code}'),
            subtitle: Text(_summary(l.state)),
            trailing: Text(
              '${l.rssi} dBm',
              style: const TextStyle(color: Colors.grey),
            ),
            onTap: () => _follower.follow(l.state.sessionId),
          ),
      ],
    );
  }

  static String _summary(BandSyncState s) {
    final target = s.freeRunning
        ? 'free running'
        : s.targetBpm == null
        ? 'no target'
        : 'target ${s.targetBpm!.round()}';
    final heard = s.detectedBpm == null
        ? 'listening'
        : 'heard ${s.detectedBpm!.toStringAsFixed(1)}';
    return '$target · $heard';
  }

  static Color? _driftColor(DriftLevel? level) => switch (level) {
    DriftLevel.onTempo => Colors.greenAccent,
    DriftLevel.drifting => Colors.amber,
    DriftLevel.off => Colors.redAccent,
    null => null,
  };

  Widget _buildMirror(BuildContext context) {
    final s = _follower.state;
    final details = _follower.details;
    final link = _follower.link;
    final theme = Theme.of(context);
    if (s == null) {
      return _message(Icons.bluetooth_searching, 'Waiting for the leader…');
    }

    final song = details?.songAt(s.songIndex);
    final next = s.songIndex == null ? null : details?.songAt(s.songIndex! + 1);
    final live = link == BandSyncLink.live;
    final heardColor = live ? _driftColor(s.drift) : Colors.grey;
    final delta = (s.detectedBpm != null && s.targetBpm != null)
        ? s.detectedBpm! - s.targetBpm!
        : null;

    final songInfo = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (details != null && details.playlistName.isNotEmpty)
          Text(
            details.playlistName,
            style: theme.textTheme.titleSmall?.copyWith(color: Colors.grey),
          ),
        Text(
          s.freeRunning
              ? 'Free running'
              : song ??
                    (s.songIndex == null ? '—' : 'Song ${s.songIndex! + 1}'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineMedium,
        ),
        if (next != null && !s.freeRunning)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Up next: $next',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ),
        if (_follower.isReadingDetails && details == null)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Getting song names…',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        if (_follower.detailsError != null && details == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _follower.detailsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        const SizedBox(height: 16),
        if (!s.freeRunning)
          Text(
            s.targetBpm == null
                ? 'No target'
                : 'Target ${s.targetBpm!.round()} BPM',
            style: theme.textTheme.titleLarge,
          ),
        if (s.metronomePlaying)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.graphic_eq, size: 16, color: Colors.tealAccent),
                SizedBox(width: 4),
                Text(
                  'Count-in metronome on',
                  style: TextStyle(color: Colors.tealAccent),
                ),
              ],
            ),
          ),
      ],
    );

    final heard = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          child: Text(
            s.detectedBpm == null ? '—' : s.detectedBpm!.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 96,
              fontWeight: FontWeight.bold,
              color: heardColor ?? theme.colorScheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(
          s.detectedBpm == null ? 'leader is listening…' : 'BPM heard',
          style: const TextStyle(color: Colors.grey),
        ),
        if (live && s.drift != null && delta != null && !s.freeRunning)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              s.drift == DriftLevel.onTempo
                  ? '✓ on tempo'
                  : s.rushing
                  ? '▲ +${delta.abs().toStringAsFixed(1)} rushing'
                  : '▼ −${delta.abs().toStringAsFixed(1)} dragging',
              style: TextStyle(
                color: heardColor,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(height: 8),
        _confidenceBar(s.confidence, live),
      ],
    );

    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Column(
      children: [
        _linkBanner(link),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: landscape
                ? Row(
                    children: [
                      Expanded(child: Center(child: songInfo)),
                      Expanded(child: Center(child: heard)),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [songInfo, heard],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _confidenceBar(double c, bool live) {
    final color = !live
        ? Colors.grey
        : c >= 0.5
        ? Colors.greenAccent
        : c >= 0.2
        ? Colors.amber
        : Colors.redAccent;
    return SizedBox(
      width: 160,
      child: Column(
        children: [
          LinearProgressIndicator(
            value: c,
            color: color,
            backgroundColor: Colors.white12,
          ),
          const SizedBox(height: 4),
          const Text(
            'confidence',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Never let a frozen reading look live.
  Widget _linkBanner(BandSyncLink link) {
    if (link == BandSyncLink.live) return const SizedBox(height: 0);
    final last = _follower.freshness.lastNews;
    final ago = last == null ? null : DateTime.now().difference(last).inSeconds;
    final lost = link == BandSyncLink.lost;
    return Container(
      width: double.infinity,
      color: lost ? Colors.red.shade900 : Colors.amber.shade900,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Text(
        lost
            ? 'Lost the leader${ago == null ? '' : ' ($ago s ago)'} — '
                  'searching…'
            : 'No update from the leader for $ago s',
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}
