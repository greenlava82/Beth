import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'playlist.dart';
import 'playlist_text.dart';
import 'tempo_detector.dart';
import 'tempo_drift.dart';
import 'tempo_lock.dart';

void main() {
  runApp(const SCBeatWizApp());
}

class SCBeatWizApp extends StatelessWidget {
  const SCBeatWizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SC Beat Wizard',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        useMaterial3: true,
      ),
      home: const MetronomeScreen(),
    );
  }
}

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Playlist State
  List<Playlist> _playlists = defaultPlaylists();
  int _currentPlaylistIndex = 0;
  int _currentSetlistIndex = 0;
  bool _isLoadingPlaylists = true;

  // Visual Metronome
  late AnimationController _metronomeController;
  late Animation<double> _pulseAnimation;
  bool _isMetronomePlaying = false;

  // Audio Recording & BPM Detection
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSub;
  bool _isRecording = false;

  // Chart Data
  final List<FlSpot> _bpmHistory = [];
  // How long readings stay on the graph before expiring. Default is about
  // one song.
  static const List<int> _historyMinuteOptions = [1, 2, 3, 4, 5, 8, 10];
  int _historyMinutes = 4;
  double get _historyWindowSeconds => _historyMinutes * 60.0;
  int _timeCounterMs = 0;
  Timer? _chartTimer;
  double _currentCalculatedBpm = 0;

  // Tempo detection
  static const int _sampleRate = 44100;
  static const double _minDisplayConfidence = 0.1;
  // Tighter octave prior: the current song's BPM tells us whether the band
  // is at 60 or 120, so lean on it for the half/double-time choice.
  final TempoDetector _tempoDetector =
      TempoDetector(sampleRate: _sampleRate, priorOctaveWidth: 0.6);
  double _detectionConfidence = 0;
  // Count-in: the metronome auto-starts on a new song and pauses itself
  // once the band's detected tempo locks onto the song's marking.
  final TempoLock _tempoLock = TempoLock();
  // How far the heard tempo is from the song's target (null = no reading).
  final TempoDriftTracker _driftTracker = TempoDriftTracker();
  // Free-running mode: no song target; the detector leans toward the most
  // common tempos and the graph fills the screen.
  bool _freeRunning = false;
  static const double _commonTempoBpm = 120;
  static const RangeValues _commonTempoRange = RangeValues(80, 160);
  TempoDrift? _drift;
  // Preferred tempo range: picks between half/double-time readings.
  static const double _rangeLimitMin = 40;
  static const double _rangeLimitMax = 220;
  RangeValues _preferredRange = const RangeValues(90, 160);

  // MIDI
  final MidiCommand _midiCommand = MidiCommand();
  StreamSubscription<MidiPacket>? _midiSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPlaylists();
    _setupMetronome();
    _setupMidi();
    _requestMicPermissionAndStart();

    _chartTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _timeCounterMs += 1000;
        final seconds = _timeCounterMs / 1000.0;
        if (_currentCalculatedBpm > 0) {
          _bpmHistory.add(FlSpot(seconds, _currentCalculatedBpm));
        } else {
          _bpmHistory.add(FlSpot.nullSpot);
        }

        _trimHistory();
      });
    });
  }

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String? playlistsJson = prefs.getString('playlists');

    final savedMin = prefs.getDouble('preferredMinBpm');
    final savedMax = prefs.getDouble('preferredMaxBpm');

    final savedHistory = prefs.getInt('historyMinutes');
    if (savedHistory != null && _historyMinuteOptions.contains(savedHistory)) {
      _historyMinutes = savedHistory;
    }
    if (savedMin != null && savedMax != null) {
      _setPreferredRange(RangeValues(
        savedMin.clamp(_rangeLimitMin, _rangeLimitMax),
        savedMax.clamp(_rangeLimitMin, _rangeLimitMax),
      ));
    }
    
    final saved = decodePlaylists(playlistsJson);
    if (saved != null) {
      setState(() => _playlists = saved);
    } else if (playlistsJson != null) {
      // Unreadable data: keep the defaults rather than crash.
      debugPrint('Could not read saved playlists; using defaults');
    }

    // Pick up where we left off (e.g. after the app was killed mid-set).
    final savedPlaylist = prefs.getInt('currentPlaylist') ?? 0;
    _currentPlaylistIndex = savedPlaylist.clamp(0, _playlists.length - 1);
    final songCount = _playlists[_currentPlaylistIndex].items.length;
    _currentSetlistIndex = songCount == 0
        ? 0
        : (prefs.getInt('currentSong') ?? 0).clamp(0, songCount - 1);
    
    setState(() {
      _isLoadingPlaylists = false;
      _updateMetronomeTempo();
    });
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('playlists', encodePlaylists(_playlists));
  }

  /// Slide the preferred range so it is centred (on a log scale, i.e. by
  /// ratio) on [targetBpm], keeping the width the user chose. 90–160 is
  /// centred on 120; for an 80 BPM song the same width gives 60–105.
  /// Doesn't call setState — callers rebuild.
  void _centerPreferredRangeOn(double targetBpm) {
    const step = 5.0;
    double snap(double v) => (v / step).round() * step;
    final ratio = math.max(_preferredRange.end / _preferredRange.start, 1.1);
    final halfRatio = math.sqrt(ratio);
    var lo = snap(targetBpm / halfRatio);
    var hi = snap(targetBpm * halfRatio);
    // Keep within the slider's limits, preserving the width where possible.
    if (lo < _rangeLimitMin) {
      lo = _rangeLimitMin;
      hi = math.min(_rangeLimitMax, snap(lo * ratio));
    } else if (hi > _rangeLimitMax) {
      hi = _rangeLimitMax;
      lo = math.max(_rangeLimitMin, snap(hi / ratio));
    }
    if (hi - lo < 10) hi = math.min(_rangeLimitMax, lo + 10);
    _preferredRange = RangeValues(lo, hi);
    _tempoDetector.setPreferredRange(lo, hi);
  }

  void _setPreferredRange(RangeValues values) {
    setState(() => _preferredRange = values);
    _tempoDetector.setPreferredRange(values.start, values.end);
  }

  /// Expire readings older than the history window (one entry per second).
  void _trimHistory() {
    final excess = _bpmHistory.length - _historyWindowSeconds.round();
    if (excess > 0) _bpmHistory.removeRange(0, excess);
  }

  void _setHistoryMinutes(int minutes) {
    setState(() {
      _historyMinutes = minutes;
      _trimHistory();
    });
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt('historyMinutes', minutes));
  }

  Widget _buildHistoryChip(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'How long readings stay on the graph',
      initialValue: _historyMinutes,
      onSelected: _setHistoryMinutes,
      itemBuilder: (context) => [
        for (final m in _historyMinuteOptions)
          PopupMenuItem(value: m, child: Text('Keep $m min')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withAlpha(170),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 14, color: Colors.grey[300]),
            const SizedBox(width: 4),
            Text(
              '$_historyMinutes min',
              style: TextStyle(color: Colors.grey[300], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _savePreferredRange() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('preferredMinBpm', _preferredRange.start);
    await prefs.setDouble('preferredMaxBpm', _preferredRange.end);
  }

  void _setupMetronome() {
    _metronomeController = AnimationController(vsync: this);
    _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _metronomeController,
        curve: Curves.easeOut,
      ),
    );
    _updateMetronomeTempo();
  }

  void _updateMetronomeTempo() {
    if (_playlists.isEmpty) return;
    
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) {
      _metronomeController.stop();
      _metronomeController.reset();
      return;
    }
    
    // Bounds check in case playlist was edited
    if (_currentSetlistIndex >= playlist.items.length) {
      _currentSetlistIndex = 0;
    }

    final targetBpm = playlist.items[_currentSetlistIndex].bpm;
    if (!_freeRunning) {
      _tempoDetector.expectedBpm = targetBpm.toDouble();
      _centerPreferredRangeOn(targetBpm.toDouble());
    }
    final msPerBeat = (60000 / targetBpm).round();
    _metronomeController.duration = Duration(milliseconds: msPerBeat);
    if (_isMetronomePlaying) {
      _metronomeController.repeat();
    } else {
      _metronomeController.stop();
      _metronomeController.reset();
    }
    _saveSetlistPosition();
  }

  /// Remember the current playlist and song across restarts. Skipped while
  /// loading so the defaults don't overwrite the saved position.
  void _saveSetlistPosition() {
    if (_isLoadingPlaylists) return;
    final playlist = _currentPlaylistIndex, song = _currentSetlistIndex;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('currentPlaylist', playlist);
      prefs.setInt('currentSong', song);
    });
  }

  static const int _minSongBpm = 30;
  static const int _maxSongBpm = 300;

  /// Change a song's BPM, persist it, and retune the metronome / detector
  /// if it's the current song.
  void _setSongBpm(SetlistItem song, int bpm) {
    bpm = bpm.clamp(_minSongBpm, _maxSongBpm);
    if (bpm == song.bpm) return;
    setState(() {
      song.bpm = bpm;
      _updateMetronomeTempo();
    });
    final playlist = _playlists[_currentPlaylistIndex];
    final isCurrent = playlist.items.isNotEmpty &&
        identical(playlist.items[_currentSetlistIndex], song);
    // If we're still counting in, watch for the new target instead.
    if (isCurrent && _tempoLock.isArmed) _tempoLock.arm(bpm.toDouble());
    _savePlaylists();
  }

  void _nudgeCurrentSongBpm(int delta) {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) return;
    final song = playlist.items[_currentSetlistIndex];
    _setSongBpm(song, song.bpm + delta);
  }

  /// Overwrite the current song's BPM with the tempo being heard.
  void _captureDetectedBpm() {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty || _currentCalculatedBpm <= 0) return;
    final song = playlist.items[_currentSetlistIndex];
    final previous = song.bpm;
    final captured = _currentCalculatedBpm.round();
    _setSongBpm(song, captured);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Saved $captured BPM to "${song.name}" (was $previous)'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _setSongBpm(song, previous),
        ),
      ));
  }

  Widget _buildNudgeColumn(Playlist playlist, List<int> deltas) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final d in deltas) ...[
          SizedBox(
            width: 56,
            height: 40,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
              onPressed:
                  playlist.items.isEmpty ? null : () => _nudgeCurrentSongBpm(d),
              child: Text(
                d > 0 ? '+$d' : '−${-d}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (d != deltas.last) const SizedBox(height: 12),
        ],
      ],
    );
  }

  void _toggleMetronome() {
    // Manual control wins: don't auto-pause a metronome the user started.
    _tempoLock.disarm();
    setState(() {
      _isMetronomePlaying = !_isMetronomePlaying;
      _updateMetronomeTempo();
    });
  }

  /// Switch free-running mode on or off. On: stop the metronome and the
  /// count-in lock, drop the song target, and weight detection toward the
  /// most common tempos. Off: back to the current song's target and range.
  void _setFreeRunning(bool on) {
    setState(() {
      _freeRunning = on;
      _driftTracker.reset();
      _drift = null;
      if (on) {
        _tempoLock.disarm();
        _isMetronomePlaying = false;
        _tempoDetector.expectedBpm = _commonTempoBpm;
        _tempoDetector.setPreferredRange(
            _commonTempoRange.start, _commonTempoRange.end);
      }
      _updateMetronomeTempo();
    });
  }

  /// Move to song [index] of the current playlist and start its count-in:
  /// the metronome starts on beat 1, the detector listens afresh, and the
  /// metronome pauses once the band locks onto the song's marking.
  void _goToSong(int index) {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) return;
    // Picking a song means playing to its target again.
    if (_freeRunning) _setFreeRunning(false);
    setState(() {
      _currentSetlistIndex = index.clamp(0, playlist.items.length - 1);
      _isMetronomePlaying = true;
      _metronomeController.reset();
      _updateMetronomeTempo();
      _tempoDetector.reset();
      _currentCalculatedBpm = 0;
      _driftTracker.reset();
      _drift = null;
      _tempoLock.arm(playlist.items[_currentSetlistIndex].bpm.toDouble());
    });
  }

  bool get _isLastSong {
    final playlist = _playlists[_currentPlaylistIndex];
    return _currentSetlistIndex >= playlist.items.length - 1;
  }

  /// Next song; from the last song, go back to the top of the set (and say
  /// so) rather than wrapping silently.
  void _advanceSetlist() {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) return;
    if (_isLastSong) {
      _goToSong(0);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Back to the top of "${playlist.name}"'),
          duration: const Duration(seconds: 2),
        ));
    } else {
      _goToSong(_currentSetlistIndex + 1);
    }
  }

  void _previousSong() {
    if (_currentSetlistIndex > 0) _goToSong(_currentSetlistIndex - 1);
  }

  /// Bottom sheet listing the whole setlist; tap a song to jump to it.
  void _showSetlistSheet() {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) return;
    final total = playlistDuration(playlist);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (context, scroll) => Column(
            children: [
              ListTile(
                title: Text(playlist.name,
                    style: Theme.of(context).textTheme.titleLarge),
                subtitle: Text([
                  '${playlist.items.length} songs',
                  if (total.known > 0)
                    '${formatDuration(total.seconds)}'
                        '${total.known < playlist.items.length ? ' (${total.known} timed)' : ''}',
                ].join(' · ')),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: playlist.items.length,
                  itemBuilder: (context, i) {
                    final song = playlist.items[i];
                    final isCurrent = i == _currentSetlistIndex;
                    return ListTile(
                      selected: isCurrent,
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: isCurrent
                            ? colors.primary
                            : colors.surfaceContainerHighest,
                        foregroundColor:
                            isCurrent ? colors.onPrimary : colors.onSurface,
                        child: Text('${i + 1}'),
                      ),
                      title: Text(song.name),
                      subtitle: Text([
                        '${song.bpm} BPM',
                        song.timeSignature,
                        if (song.durationSeconds != null)
                          formatDuration(song.durationSeconds!),
                      ].join(' · ')),
                      trailing: isCurrent ? const Text('NOW') : null,
                      onTap: () {
                        Navigator.pop(context);
                        _goToSong(i);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _setupMidi() async {
    _midiSub = _midiCommand.onMidiDataReceived?.listen((MidiPacket packet) {
      if (packet.data.isNotEmpty) {
        final status = packet.data[0];
        // 0x90 to 0x9F are Note On messages, 0xB0 to 0xBF are Control Change
        if ((status >= 0x90 && status <= 0x9F) ||
            (status >= 0xB0 && status <= 0xBF)) {
          // Simplistic trigger: any Note On or CC advances the setlist
          SchedulerBinding.instance.addPostFrameCallback((_) {
            _advanceSetlist();
          });
        }
      }
    });
  }

  Future<void> _requestMicPermissionAndStart() async {
    var status = await Permission.microphone.request();
    if (status.isGranted) {
      _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final stream = await _audioRecorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ));

      _tempoDetector.reset();
      setState(() => _isRecording = true);
      // Keep the screen on while listening (released when the mic is
      // turned off; the OS also drops it when the app leaves the screen).
      WakelockPlus.enable();

      _audioStreamSub = stream.listen((Uint8List data) {
        _processAudioBuffer(data);
      });
    }
  }

  void _stopRecording() {
    _audioStreamSub?.cancel();
    _audioStreamSub = null;
    _audioRecorder.stop();
    WakelockPlus.disable();
    setState(() {
      _isRecording = false;
      _currentCalculatedBpm = 0;
      _drift = null;
    });
  }

  // True while listening is paused only because the app left the screen.
  bool _pausedInBackground = false;

  /// Stop listening when the app goes to the background or the screen locks
  /// (Android silences the mic there anyway, so detection would just burn
  /// battery on silence), and pick up again on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_isRecording) {
          _pausedInBackground = true;
          _stopRecording();
        }
      case AppLifecycleState.resumed:
        if (_pausedInBackground) {
          _pausedInBackground = false;
          _startRecording();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  // Feed mic audio into the tempo detector; it emits a new estimate
  // roughly twice a second.
  void _processAudioBuffer(Uint8List data) {
    final before = _tempoDetector.current;
    _tempoDetector.addPcm16(data);
    final now = _tempoDetector.current;
    if (identical(before, now)) return;
    setState(() {
      _detectionConfidence = now?.confidence ?? 0;
      _currentCalculatedBpm =
          (now == null || now.confidence < _minDisplayConfidence) ? 0 : now.bpm;
      final playlist = _playlists[_currentPlaylistIndex];
      _drift = playlist.items.isEmpty || _freeRunning
          ? null
          : _driftTracker.update(_currentCalculatedBpm,
              playlist.items[_currentSetlistIndex].bpm.toDouble(),
              confidence: _detectionConfidence);
    });

    if (_isMetronomePlaying && _tempoLock.update(now, DateTime.now())) {
      setState(() {
        _isMetronomePlaying = false;
        _updateMetronomeTempo();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Locked on ${now!.bpm.toStringAsFixed(1)} BPM — metronome paused'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chartTimer?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _midiSub?.cancel();
    _metronomeController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ==========================================================================
  // Playlist management
  // ==========================================================================

  void _openPlaylistEditor(Playlist playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistEditScreen(
          playlist: playlist,
          onChanged: () {
            setState(_updateMetronomeTempo);
            _savePlaylists();
          },
        ),
      ),
    );
  }

  /// Run [change] on the playlist list while keeping the current playlist
  /// (and song) selected, wherever it ends up.
  void _changePlaylists(void Function() change) {
    final current = _playlists[_currentPlaylistIndex];
    setState(() {
      change();
      final i = _playlists.indexOf(current);
      if (i >= 0) {
        _currentPlaylistIndex = i;
      } else {
        // The current playlist went away: fall back to a neighbour.
        _currentPlaylistIndex =
            _currentPlaylistIndex.clamp(0, _playlists.length - 1);
        _currentSetlistIndex = 0;
      }
      _updateMetronomeTempo();
    });
    _savePlaylists();
  }

  void _reorderPlaylists(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    _changePlaylists(() {
      _playlists.insert(newIndex, _playlists.removeAt(oldIndex));
    });
  }

  void _duplicatePlaylist(int index) {
    final original = _playlists[index];
    _changePlaylists(() {
      // The copy appears right below the original in the open drawer.
      _playlists.insert(index + 1, original.copy(name: '${original.name} (copy)'));
    });
  }

  Future<void> _confirmDeletePlaylist(int index) async {
    final playlist = _playlists[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${playlist.name}"?'),
        content: Text('Its ${playlist.items.length} songs will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Close the drawer so the Undo snackbar isn't hidden behind it.
    Navigator.pop(context);

    final wasCurrent = index == _currentPlaylistIndex;
    final songIndex = _currentSetlistIndex;
    _changePlaylists(() => _playlists.removeAt(index));
    _showSnack('Deleted "${playlist.name}"', undo: () {
      _changePlaylists(() => _playlists.insert(index, playlist));
      if (wasCurrent) {
        setState(() {
          _currentPlaylistIndex = index;
          _currentSetlistIndex = songIndex;
          _updateMetronomeTempo();
        });
      }
    });
  }

  Future<void> _sharePlaylist(Playlist playlist) async {
    await SharePlus.instance.share(ShareParams(
      text: playlistToText(playlist),
      subject: '${playlist.name} (SCBeatWiz setlist)',
    ));
  }

  /// [base], or "[base] (2)", "(3)"… if a playlist already has that name.
  String _uniquePlaylistName(String base) {
    final names = _playlists.map((p) => p.name).toSet();
    if (!names.contains(base)) return base;
    for (var n = 2;; n++) {
      final candidate = '$base ($n)';
      if (!names.contains(candidate)) return candidate;
    }
  }

  Future<void> _showImportDialog() async {
    final controller = TextEditingController();
    var preview = parsePlaylistText('');
    final result = await showDialog<PlaylistImport>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void update() =>
              setDialogState(() => preview = parsePlaylistText(controller.text));
          final songs = preview.songCount;
          final skipped = preview.skippedLines.length;
          return AlertDialog(
            title: const Text('Import Playlist'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Paste a setlist shared from SCBeatWiz, or one song per '
                    'line like "Superstition, 100".',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '# Setlist: Friday Gig\nSuperstition, 100\nValerie, 118',
                    ),
                    onChanged: (_) => update(),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Paste'),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text == null) return;
                        controller.text = data!.text!;
                        update();
                      },
                    ),
                  ),
                  Text(
                    songs == 0
                        ? (controller.text.trim().isEmpty ? '' : 'No songs found')
                        : 'Found $songs song${songs == 1 ? '' : 's'}'
                            '${preview.playlists.length > 1 ? ' in ${preview.playlists.length} playlists' : ''}'
                            '${skipped > 0 ? ' · $skipped line${skipped == 1 ? '' : 's'} skipped' : ''}',
                    style: TextStyle(
                        color: songs == 0 ? Colors.redAccent : Colors.grey[300]),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: songs == 0 ? null : () => Navigator.pop(context, preview),
                child: const Text('Import'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || result.playlists.isEmpty || !mounted) return;

    final first = _playlists.length;
    setState(() {
      for (final p in result.playlists) {
        p.name = _uniquePlaylistName(p.name);
        _playlists.add(p);
      }
      // Switch to the (first) imported playlist.
      _currentPlaylistIndex = first;
      _currentSetlistIndex = 0;
      _updateMetronomeTempo();
    });
    _savePlaylists();
    final skipped = result.skippedLines.length;
    _showSnack('Imported "${_playlists[first].name}" '
        '(${result.songCount} songs'
        '${skipped > 0 ? ', $skipped line${skipped == 1 ? '' : 's'} skipped' : ''})');
  }

  void _showSnack(String message, {VoidCallback? undo}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: undo),
      ));
  }

  Widget _buildDrawer() {
    return Drawer(
      // Keep the bottom items (e.g. Import Playlist) clear of the system
      // navigation bar; the header still fills in under the status bar.
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.teal),
              child: Center(
                child: Text('Playlists', style: TextStyle(color: Colors.white, fontSize: 24)),
              ),
            ),
            Expanded(
              // Long-press and drag to reorder.
              child: ReorderableListView.builder(
                itemCount: _playlists.length,
                onReorder: _reorderPlaylists,
                itemBuilder: (context, index) {
                  final playlist = _playlists[index];
                  final total = playlistDuration(playlist);
                  return ListTile(
                    key: ObjectKey(playlist),
                    title: Text(playlist.name),
                    subtitle: Text([
                      '${playlist.items.length} songs',
                      if (total.known > 0) formatDuration(total.seconds),
                    ].join(' · ')),
                    selected: _currentPlaylistIndex == index,
                    onTap: () {
                      setState(() {
                        _currentPlaylistIndex = index;
                        _currentSetlistIndex = 0;
                        _updateMetronomeTempo();
                      });
                      Navigator.pop(context);
                    },
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Playlist actions',
                      onSelected: (action) {
                        switch (action) {
                          case 'edit':
                            _openPlaylistEditor(playlist);
                          case 'duplicate':
                            _duplicatePlaylist(index);
                          case 'share':
                            _sharePlaylist(playlist);
                          case 'delete':
                            _confirmDeletePlaylist(index);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: ListTile(leading: Icon(Icons.edit), title: Text('Edit')),
                        ),
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: ListTile(leading: Icon(Icons.copy), title: Text('Duplicate')),
                        ),
                        const PopupMenuItem(
                          value: 'share',
                          child: ListTile(leading: Icon(Icons.share), title: Text('Share')),
                        ),
                        // Keep at least one playlist.
                        if (_playlists.length > 1)
                          const PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: Icon(Icons.delete, color: Colors.redAccent),
                              title: Text('Delete'),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New Playlist'),
              onTap: () {
                Navigator.pop(context); // close drawer
                _showAddPlaylistDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Import Playlist'),
              onTap: () {
                Navigator.pop(context); // close drawer
                _showImportDialog();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showAddPlaylistDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) {
                  setState(() {
                    _playlists.add(Playlist(newName, []));
                  });
                  _savePlaylists();
                }
                Navigator.pop(context);
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // Tempo graph
  // ==========================================================================

  static const double _minChartWindowSeconds = 30;

  /// Seconds of history the time axis shows: just the span that actually
  /// has readings (at least 30 s, at most the full history window).
  double _chartWindowSeconds() {
    final now = _timeCounterMs / 1000.0;
    for (final spot in _bpmHistory) {
      if (!spot.x.isNaN) {
        return (now - spot.x)
            .clamp(_minChartWindowSeconds, _historyWindowSeconds)
            .toDouble();
      }
    }
    return _minChartWindowSeconds;
  }

  /// BPM axis range fitted to the readings currently on screen, with
  /// headroom on top for the tempo readout. Returns (minY, maxY, step).
  /// The current song's BPM, or null with an empty playlist.
  /// The range the detector currently favours (shaded on the graph).
  RangeValues get _bandRange => _freeRunning ? _commonTempoRange : _preferredRange;

  double? get _currentTargetBpm {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty || _freeRunning) return null;
    return playlist.items[_currentSetlistIndex].bpm.toDouble();
  }

  (double, double, double) _chartYRange(double minX) {
    double? lo, hi;
    for (final spot in _bpmHistory) {
      if (spot.x.isNaN || spot.x < minX) continue;
      lo = lo == null ? spot.y : math.min(lo, spot.y);
      hi = hi == null ? spot.y : math.max(hi, spot.y);
    }
    // No readings yet: frame the preferred range.
    lo ??= _preferredRange.start;
    hi ??= _preferredRange.end;
    // Keep the target line in view so drift can be seen against it.
    final target = _currentTargetBpm;
    if (target != null) {
      lo = math.min(lo, target);
      hi = math.max(hi, target);
    }

    // At least 30 BPM of span so a steady tempo isn't magnified into noise.
    if (hi - lo < 30) {
      final mid = (lo + hi) / 2;
      lo = mid - 15;
      hi = mid + 15;
    }
    final span = hi - lo;
    final step = span <= 40 ? 10.0 : (span <= 90 ? 20.0 : 40.0);
    // Bottom padding, then enough headroom that the readings sit in the
    // lower ~60% of the plot, clear of the overlaid readout.
    var minY = ((lo - step / 2) / step).floorToDouble() * step;
    var maxY = ((hi + (hi - minY) * 0.65) / step).ceilToDouble() * step;
    minY = math.max(0, minY);
    maxY = math.min(300, maxY);
    return (minY, maxY, step);
  }

  static String _formatAgo(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _buildTempoChart(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final now = _timeCounterMs / 1000.0;
    final window = _chartWindowSeconds();
    final labelInterval = window <= 60 ? 10.0 : (window <= 150 ? 30.0 : 60.0);
    final (minY, maxY, yStep) = _chartYRange(now - window);
    // Plot against "seconds ago" (now = 0, past is negative) so ticks land
    // on round ages: 4:00, 3:00, 2:00, 1:00, now.
    final spots = [
      for (final spot in _bpmHistory)
        spot.x.isNaN ? spot : FlSpot(spot.x - now, spot.y),
    ];
    return LineChart(
      // No tween between updates: the graph changes ~3 times a second, and
      // the default 150 ms animation made the whole screen redraw ~30 times
      // a second (most of the app's battery use while listening).
      duration: Duration.zero,
      LineChartData(
        gridData: FlGridData(
          show: true,
          horizontalInterval: yStep,
          verticalInterval: labelInterval,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: labelInterval,
              getTitlesWidget: (value, meta) {
                // fl_chart also labels the window edges; skip them unless
                // they fall on a round age.
                if (value.round() % labelInterval.round() != 0) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                  child: Text(
                    value == 0 ? 'now' : _formatAgo(-value),
                    style: TextStyle(color: Colors.grey[500], fontSize: 10),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: yStep,
              getTitlesWidget: (value, meta) {
                // Skip off-step edge labels that would collide with a
                // neighbouring label.
                if (value % yStep != 0) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    value.round().toString(),
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true),
        minY: minY,
        maxY: maxY,
        // The song's target BPM, to see drift against.
        extraLinesData: ExtraLinesData(horizontalLines: [
          if (_currentTargetBpm != null)
            HorizontalLine(
              y: _currentTargetBpm!,
              color: Colors.white.withAlpha(170),
              strokeWidth: 1.5,
              dashArray: const [6, 4],
              label: HorizontalLineLabel(
                show: true,
                alignment: Alignment.bottomLeft,
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                style: TextStyle(color: Colors.grey[300], fontSize: 10),
                labelResolver: (line) => 'target ${line.y.round()}',
              ),
            ),
        ]),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            // fl_chart doesn't clip range annotations to the plot, so clamp
            // the band to the visible BPM range or it spills over the slider
            // and the controls when the preferred range is wider.
            HorizontalRangeAnnotation(
              y1: _bandRange.start.clamp(minY, maxY),
              y2: _bandRange.end.clamp(minY, maxY),
              color: colors.primary.withAlpha(25),
            ),
          ],
        ),
        minX: -window,
        maxX: 0,
        clipData: const FlClipData.all(),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            color: colors.primary,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: colors.primary.withAlpha(51),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTempoReadout(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasTempo = _currentCalculatedBpm > 0;
    final parts = _currentCalculatedBpm.toStringAsFixed(1).split('.');
    const shadow = [Shadow(blurRadius: 12, color: Colors.black)];
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        decoration: BoxDecoration(
          color: colors.surface.withAlpha(150),
          borderRadius: BorderRadius.circular(16),
        ),
        child: hasTempo
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: parts[0],
                        style: const TextStyle(
                            fontSize: 56, fontWeight: FontWeight.w800, height: 1.1),
                      ),
                      TextSpan(
                        text: '.${parts[1]}',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '  BPM',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey[400]),
                      ),
                    ]),
                    // The number takes the drift colour: green / amber / red.
                    style: TextStyle(
                        color: _driftColor(_drift) ?? Colors.white, shadows: shadow),
                  ),
                  if (_drift != null) _buildDriftBadge(_drift!),
                ],
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  _isRecording ? 'Listening…' : 'Mic off',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[400],
                      shadows: shadow),
                ),
              ),
      ),
    );
  }

  static Color? _driftColor(TempoDrift? drift) => switch (drift?.level) {
        DriftLevel.onTempo => Colors.greenAccent,
        DriftLevel.drifting => Colors.amber,
        DriftLevel.off => Colors.redAccent,
        null => null,
      };

  /// "✓ on tempo" / "▲ +3.1 rushing" / "▼ −2.0 dragging", in the drift colour.
  Widget _buildDriftBadge(TempoDrift drift) {
    final color = _driftColor(drift)!;
    final onTempo = drift.level == DriftLevel.onTempo;
    final amount = drift.deltaBpm.abs().toStringAsFixed(1);
    final label = onTempo
        ? 'on tempo'
        : drift.isRushing
            ? '+$amount rushing'
            : '−$amount dragging';
    final octave = drift.octave == 2
        ? ' · at 2× time'
        : drift.octave == 0.5
            ? ' · at ½ time'
            : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            onTempo
                ? Icons.check_circle
                : drift.isRushing
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$label$octave',
            style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildConfidenceIndicator(BuildContext context) {
    // Thresholds match what the detector reports in practice: a solid
    // drum groove is ~0.9, sparse piano ~0.3, noise < 0.1.
    final hasEstimate = _isRecording && _tempoDetector.current != null;
    final c = _detectionConfidence;
    final (Color color, String label) = !hasEstimate
        ? (Colors.grey, 'No beat')
        : c >= 0.4
            ? (Colors.greenAccent, 'Strong')
            : c >= 0.2
                ? (Colors.amber, 'Fair')
                : (Colors.redAccent, 'Weak');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withAlpha(170),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                if (hasEstimate) BoxShadow(color: color.withAlpha(160), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            hasEstimate ? '$label  ${(c * 100).round()}%' : label,
            style: TextStyle(color: Colors.grey[300], fontSize: 11),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingPlaylists) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final playlist = _playlists[_currentPlaylistIndex];
    
    // Fallback if the active playlist has no songs
    final currentItem = playlist.items.isNotEmpty
        ? playlist.items[_currentSetlistIndex]
        : SetlistItem('Empty Playlist', 120);

    return Scaffold(
      appBar: AppBar(
        // The SCBeatWiz mark opens the playlists drawer (in place of the
        // usual hamburger icon); the title is the current playlist.
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Playlists',
            onPressed: () => Scaffold.of(context).openDrawer(),
            // The image has padding around the mark; 40 makes the mark itself
            // about the size of a regular toolbar icon.
            icon: Image.asset('assets/branding/splash.png', height: 40),
          ),
        ),
        title: Text(_freeRunning ? 'Free running' : playlist.name,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _freeRunning ? 'Back to setlist' : 'Free-running mode',
            icon: Icon(_freeRunning ? Icons.close_fullscreen : Icons.open_in_full),
            onPressed: () => _setFreeRunning(!_freeRunning),
          ),
          IconButton(
            icon: Icon(_isRecording ? Icons.mic : Icons.mic_off),
            color: _isRecording ? Colors.redAccent : Colors.grey,
            onPressed: () {
              if (_isRecording) {
                _stopRecording();
              } else {
                _startRecording();
              }
            },
          )
        ],
      ),
      drawer: _buildDrawer(),
      // Keep content clear of the system bars (edge-to-edge; in landscape
      // this also keeps clear of the camera cut-out).
      body: SafeArea(
        top: false,
        child: _freeRunning
            // Free-running: just the graph, full screen, either orientation.
            ? _buildGraphSection(context)
            : MediaQuery.orientationOf(context) == Orientation.landscape
                // Landscape: graph on the left, metronome and setlist on the right.
                ? Row(
                    children: [
                      Expanded(child: _buildGraphSection(context)),
                      const VerticalDivider(width: 1, thickness: 2),
                      Expanded(
                        child: _buildControlsSection(context, playlist, currentItem,
                            landscape: true),
                      ),
                    ],
                  )
                // Portrait: graph above, metronome and setlist below.
                : Column(
                    children: [
                      Expanded(flex: 2, child: _buildGraphSection(context)),
                      const Divider(height: 1, thickness: 2),
                      Expanded(
                        flex: 3,
                        child: _buildControlsSection(context, playlist, currentItem),
                      ),
                    ],
                  ),
      ),
    );
  }

  /// Top (portrait) / left (landscape): preferred-range slider and the tempo
  /// graph with its overlays.
  Widget _buildGraphSection(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The preferred-range slider is for setlist mode; free-running
          // uses the common-tempo range.
          if (!_freeRunning)
            Row(
              children: [
                Text(
                  'Prefer ${_preferredRange.start.round()}–${_preferredRange.end.round()}',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
                Expanded(
                  child: RangeSlider(
                    values: _preferredRange,
                    min: _rangeLimitMin,
                    max: _rangeLimitMax,
                    divisions: ((_rangeLimitMax - _rangeLimitMin) / 5).round(),
                    labels: RangeLabels(
                      '${_preferredRange.start.round()}',
                      '${_preferredRange.end.round()}',
                    ),
                    onChanged: (v) {
                      // Keep at least 10 BPM between handles.
                      if (v.end - v.start < 10) return;
                      _setPreferredRange(v);
                    },
                    onChangeEnd: (_) => _savePreferredRange(),
                  ),
                ),
              ],
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildTempoChart(context)),
                // Detected tempo, overlaid on the top of the graph.
                Positioned(
                  top: 4,
                  left: 40, // clear of the left axis labels
                  right: 0,
                  child: IgnorePointer(child: _buildTempoReadout(context)),
                ),
                // Confidence light along the bottom of the plot.
                Positioned(
                  bottom: 30, // just above the time labels
                  left: 40,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(child: _buildConfidenceIndicator(context)),
                  ),
                ),
                // History length, bottom-right of the plot.
                Positioned(
                  bottom: 30,
                  right: 4,
                  child: _buildHistoryChip(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The pulsing metronome circle; also the play/stop button.
  Widget _buildMetronomeCircle(
      BuildContext context, Playlist playlist, SetlistItem currentItem,
      {double size = 136}) {
    return Semantics(
      button: true,
      label: _isMetronomePlaying ? 'Stop metronome' : 'Start metronome',
      child: GestureDetector(
        onTap: playlist.items.isEmpty ? null : _toggleMetronome,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isMetronomePlaying && playlist.items.isNotEmpty
                    ? Theme.of(context).colorScheme.secondary
                        .withAlpha(((1.0 - _pulseAnimation.value) * 255).toInt())
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                boxShadow: [
                  if (_isMetronomePlaying && playlist.items.isNotEmpty)
                    BoxShadow(
                      color: Theme.of(context)
                          .colorScheme
                          .secondary
                          .withAlpha(((0.5 * (1.0 - _pulseAnimation.value)) * 255).toInt()),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Spacer matching the icon below keeps the
                  // number centred in the circle.
                  SizedBox(height: size * 0.2),
                  Text(
                    '${currentItem.bpm}',
                    style: TextStyle(
                      fontSize: size * 0.35,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Icon(
                    _isMetronomePlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    size: size * 0.2,
                    color: _isMetronomePlaying ? Colors.redAccent : Colors.greenAccent,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Saves the heard tempo as the current song's BPM.
  Widget _buildCaptureButton(Playlist playlist) {
    return FilledButton.tonalIcon(
      onPressed: playlist.items.isEmpty || _currentCalculatedBpm <= 0
          ? null
          : _captureDetectedBpm,
      icon: const Icon(Icons.hearing),
      label: Text(_currentCalculatedBpm > 0
          ? 'Capture ${_currentCalculatedBpm.round()}'
          : 'Capture'),
    );
  }

  /// "SONG n OF m", name, time signature, notes and up next; tap for the
  /// setlist sheet.
  Widget _buildSongInfo(
      BuildContext context, Playlist playlist, SetlistItem currentItem) {
    return InkWell(
      onTap: playlist.items.isEmpty ? null : _showSetlistSheet,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  playlist.items.isEmpty
                      ? 'CURRENT'
                      : 'SONG ${_currentSetlistIndex + 1} OF ${playlist.items.length}',
                  style: TextStyle(
                    color: Colors.grey[400],
                    letterSpacing: 2,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (playlist.items.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.queue_music, size: 16, color: Colors.grey[400]),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(
              currentItem.name,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (playlist.items.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                [
                  currentItem.timeSignature,
                  if (currentItem.durationSeconds != null)
                    formatDuration(currentItem.durationSeconds!),
                ].join('  ·  '),
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
              if (currentItem.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  currentItem.notes,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.grey[300],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                _isLastSong
                    ? 'Last song of the set'
                    : 'Up next: ${playlist.items[_currentSetlistIndex + 1].name}'
                        ' · ${playlist.items[_currentSetlistIndex + 1].bpm}',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// −5 −1 +1 +5 in one compact row (landscape). Scales down to fit narrow
  /// panels, e.g. beside the camera cut-out on an iPhone.
  Widget _buildNudgeRow(Playlist playlist) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: _nudgeRowButtons(playlist),
    );
  }

  Widget _nudgeRowButtons(Playlist playlist) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final d in const [-5, -1, 1, 5])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: SizedBox(
              width: 48,
              height: 36,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                onPressed:
                    playlist.items.isEmpty ? null : () => _nudgeCurrentSongBpm(d),
                child: Text(
                  d > 0 ? '+$d' : '−${-d}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Bottom (portrait) / right (landscape): metronome, song info and the
  /// pinned Previous/Next controls.
  Widget _buildControlsSection(
      BuildContext context, Playlist playlist, SetlistItem currentItem,
      {bool landscape = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Column(
        children: [
          // Metronome and song info scroll if they don't fit; the
          // song controls below stay pinned so Next is always reachable.
          Expanded(
            child: SingleChildScrollView(
              child: landscape
                  // Landscape: metronome on the left of the panel, nudges,
                  // song info and Capture beside it.
                  ? Row(
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildMetronomeCircle(context, playlist, currentItem,
                                size: 112),
                          ],
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildNudgeRow(playlist),
                              _buildSongInfo(context, playlist, currentItem),
                              _buildCaptureButton(playlist),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Pulse Indicator, flanked by tempo nudge buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildNudgeColumn(playlist, const [-1, -5]),
                            const SizedBox(width: 16),
                            _buildMetronomeCircle(context, playlist, currentItem),
                            const SizedBox(width: 16),
                            _buildNudgeColumn(playlist, const [1, 5]),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildCaptureButton(playlist),
                        const SizedBox(height: 8),
                        _buildSongInfo(context, playlist, currentItem),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                tooltip: 'Previous song',
                iconSize: 32,
                onPressed: playlist.items.isEmpty || _currentSetlistIndex == 0
                    ? null
                    : _previousSong,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: playlist.items.isEmpty ? null : _advanceSetlist,
                icon: Icon(
                    _isLastSong ? Icons.replay : Icons.skip_next,
                    size: 32),
                label: Text(
                  _isLastSong ? 'RESTART SET' : 'NEXT SONG',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
              ),
            ],
          ),
          // The hint costs height that landscape doesn't have.
          if (!landscape) ...[
            const SizedBox(height: 6),
            Text(
              'MIDI trigger active (Any CC/Note)',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class PlaylistEditScreen extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback onChanged;

  const PlaylistEditScreen({
    super.key,
    required this.playlist,
    required this.onChanged,
  });

  @override
  State<PlaylistEditScreen> createState() => _PlaylistEditScreenState();
}

class _PlaylistEditScreenState extends State<PlaylistEditScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit: ${widget.playlist.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _showRenamePlaylistDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showSongDialog(null, null),
          ),
        ],
      ),
      body: widget.playlist.items.isEmpty
          ? const Center(child: Text('No songs in this playlist. Tap + to add.'))
          : ReorderableListView.builder(
              itemCount: widget.playlist.items.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (oldIndex < newIndex) {
                    newIndex -= 1;
                  }
                  final item = widget.playlist.items.removeAt(oldIndex);
                  widget.playlist.items.insert(newIndex, item);
                  widget.onChanged();
                });
              },
              itemBuilder: (context, index) {
                final song = widget.playlist.items[index];
                return ListTile(
                  key: ValueKey('${song.name}_${song.bpm}_$index'),
                  title: Text(song.name),
                  subtitle: Text(
                    [
                      [
                        '${song.bpm} BPM',
                        song.timeSignature,
                        if (song.durationSeconds != null)
                          formatDuration(song.durationSeconds!),
                      ].join(' · '),
                      if (song.notes.isNotEmpty) song.notes.split('\n').first,
                    ].join('\n'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _showSongDialog(index, song),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () {
                          final removed = widget.playlist.items[index];
                          setState(() {
                            widget.playlist.items.removeAt(index);
                            widget.onChanged();
                          });
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(SnackBar(
                              content: Text('Removed "${removed.name}"'),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () {
                                  // Works even after leaving the editor.
                                  widget.playlist.items.insert(
                                      index.clamp(0, widget.playlist.items.length),
                                      removed);
                                  widget.onChanged();
                                  if (mounted) setState(() {});
                                },
                              ),
                            ));
                        },
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.only(left: 8.0, right: 8.0),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _showRenamePlaylistDialog() {
    final controller = TextEditingController(text: widget.playlist.name);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Playlist'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Playlist Name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) {
                  setState(() {
                    widget.playlist.name = newName;
                    widget.onChanged();
                  });
                }
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showSongDialog(int? index, SetlistItem? currentSong) {
    final nameController = TextEditingController(text: currentSong?.name ?? '');
    final bpmController =
        TextEditingController(text: currentSong?.bpm.toString() ?? '120');
    final durationController = TextEditingController(
        text: currentSong?.durationSeconds == null
            ? ''
            : formatDuration(currentSong!.durationSeconds!));
    final notesController = TextEditingController(text: currentSong?.notes ?? '');
    var timeSignature = currentSong?.timeSignature ?? '4/4';
    String? durationError;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(currentSong == null ? 'Add Song' : 'Edit Song'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(labelText: 'Song Name'),
                    controller: nameController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(labelText: 'BPM'),
                          keyboardType: TextInputType.number,
                          controller: bpmController,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: timeSignature,
                          decoration: const InputDecoration(labelText: 'Time'),
                          items: [
                            for (final ts in timeSignatures)
                              DropdownMenuItem(value: ts, child: Text(ts)),
                          ],
                          onChanged: (v) => timeSignature = v ?? timeSignature,
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    decoration: InputDecoration(
                      labelText: 'Length (optional)',
                      hintText: 'm:ss',
                      errorText: durationError,
                    ),
                    keyboardType: TextInputType.datetime,
                    controller: durationController,
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      hintText: 'Key, cues, who starts…',
                    ),
                    controller: notesController,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final durationText = durationController.text.trim();
                  final duration = parseDuration(durationText);
                  if (durationText.isNotEmpty && duration == null) {
                    setDialogState(() => durationError = 'Use m:ss, e.g. 3:45');
                    return;
                  }
                  final bpm = (int.tryParse(bpmController.text.trim()) ?? 120)
                      .clamp(30, 300);
                  var name = nameController.text.trim();
                  if (name.isEmpty) name = 'Unnamed Song';
                  final notes = notesController.text.trim();

                  setState(() {
                    if (currentSong == null) {
                      widget.playlist.items.add(SetlistItem(name, bpm,
                          timeSignature: timeSignature,
                          notes: notes,
                          durationSeconds: duration));
                    } else {
                      currentSong
                        ..name = name
                        ..bpm = bpm
                        ..timeSignature = timeSignature
                        ..notes = notes
                        ..durationSeconds = duration;
                    }
                    widget.onChanged();
                  });
                  Navigator.pop(context);
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }
}
