import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_version.dart';
import 'band_sync.dart';
import 'band_sync_icon.dart';
import 'band_sync_icon_view.dart';
import 'band_sync_protocol.dart';
import 'band_sync_screen.dart';
import 'playlist.dart';
import 'playlist_text.dart';
import 'show_draft.dart';
import 'tap_tempo.dart';
import 'tempo_detector.dart';
import 'tempo_display_gate.dart';
import 'tempo_drift.dart';
import 'tempo_lock.dart';

void main() {
  runApp(const BethApp());
}

/// What the main screen is doing: playing a setlist, free-running (no song
/// target), or building a show (capturing tempos into a new playlist).
enum _ScreenMode { setlist, freeRunning, show }

class BethApp extends StatelessWidget {
  const BethApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beth',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        useMaterial3: true,
        // Snackbars: a floating, rounded card in the app's indigo with the
        // lavender accent, instead of the default light-grey bar.
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF2B2466),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
          actionTextColor: const Color(0xFFCFBCFF),
          elevation: 6,
          insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0x33CFBCFF)),
          ),
        ),
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
  // When the readout shows a BPM instead of "Listening…" (user settings).
  final TempoDisplayGate _displayGate = TempoDisplayGate();
  // Tighter octave prior: the current song's BPM tells us whether the band
  // is at 60 or 120, so lean on it for the half/double-time choice.
  final TempoDetector _tempoDetector =
      TempoDetector(sampleRate: _sampleRate, priorOctaveWidth: 0.6);
  double _detectionConfidence = 0;
  // Count-in: the metronome auto-starts on a new song and pauses itself
  // once the band's detected tempo locks onto the song's marking.
  final TempoLock _tempoLock = TempoLock();
  // After the lock, the metronome keeps going this long before it stops,
  // so the band gets a few more clicks once they're on tempo.
  static const Duration _runOnAfterLock = Duration(seconds: 3);
  Timer? _lockStopTimer;
  // How far the heard tempo is from the song's target (null = no reading).
  final TempoDriftTracker _driftTracker = TempoDriftTracker();
  // Free-running mode: no song target; the detector leans toward the most
  // common tempos and the graph fills the screen.
  _ScreenMode _mode = _ScreenMode.setlist;
  static const double _commonTempoBpm = 120;
  static const RangeValues _commonTempoRange = RangeValues(80, 160);
  // Show creation mode: listen wide, since any song might come next.
  static const RangeValues _showTempoRange = RangeValues(80, 160);
  ShowDraft _showDraft = ShowDraft();
  // The playlist the show is being built into (null outside the mode).
  Playlist? _showPlaylist;
  final TapTempo _tapTempo = TapTempo();
  final Stopwatch _tapClock = Stopwatch()..start();
  TempoDrift? _drift;
  // Preferred tempo range: picks between half/double-time readings.
  static const double _rangeLimitMin = 40;
  static const double _rangeLimitMax = 220;
  RangeValues _preferredRange = const RangeValues(90, 160);

  // Band sync: this phone can broadcast its song and tempo to bandmates.
  late final BandSyncLeader _bandLeader = BandSyncLeader(_bandSyncSnapshot);
  // The band's icon, kept from gig to gig (chosen at random on first lead).
  BandSyncIcon? _bandIcon;

  // This build's version (null until the platform answers).
  AppVersion? _appVersion;

  // MIDI
  final MidiCommand _midiCommand = MidiCommand();
  StreamSubscription<MidiPacket>? _midiSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bandLeader.addListener(_onBandLeaderChanged);
    _loadPlaylists();
    _loadAppVersion();
    _setupMetronome();
    _setupMidi();
    _requestMicPermissionAndStart();

    _chartTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _timeCounterMs += 1000;
        final seconds = _timeCounterMs / 1000.0;
        // A held reading expires even when no new estimate arrives.
        if (_currentCalculatedBpm > 0) {
          _currentCalculatedBpm = _displayGate.tick(DateTime.now());
        }
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

    final savedIcon = prefs.getInt('bandIcon');
    if (savedIcon != null && BandSyncIcon(savedIcon).isValid) {
      _bandIcon = BandSyncIcon(savedIcon);
    }

    _displayGate
      ..showAbove = (prefs.getDouble('showConfidence') ??
              TempoDisplayGate.defaultShowAbove)
          .clamp(_showAboveMin, _showAboveMax)
      ..hysteresis = (prefs.getDouble('confidenceHysteresis') ??
              TempoDisplayGate.defaultHysteresis)
          .clamp(0.0, _hysteresisMax)
      ..holdSeconds = (prefs.getDouble('holdSeconds') ??
              TempoDisplayGate.defaultHoldSeconds)
          .clamp(0.0, _holdMax);

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

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = AppVersion.fromPlatform(info.version, info.buildNumber);
      });
    } catch (e) {
      debugPrint('No app version: $e');
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Beth',
      applicationVersion: _appVersion?.label,
      applicationIcon: Image.asset('assets/branding/splash.png', width: 48),
      children: const [
        Text('Setlist metronome that listens to the band.'),
      ],
    );
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

  static const double _showAboveMin = 0.05, _showAboveMax = 0.5;
  static const double _hysteresisMax = 0.2, _holdMax = 10;

  Future<void> _saveDisplaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('showConfidence', _displayGate.showAbove);
    await prefs.setDouble('confidenceHysteresis', _displayGate.hysteresis);
    await prefs.setDouble('holdSeconds', _displayGate.holdSeconds);
  }

  /// Sliders for when the readout shows a BPM and how long it holds it.
  void _showDetectionSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final g = _displayGate;
          void change(void Function() f) {
            setSheet(f);
            // Re-evaluate the readout with the new settings.
            setState(() {});
            _saveDisplaySettings();
          }

          Widget slider(String title, String value, String help, double v,
                  double min, double max, int divisions,
                  ValueChanged<double> onChanged) =>
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(title)),
                    Text(value,
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  Slider(
                    value: v.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: (x) => change(() => onChanged(x)),
                  ),
                  Text(help,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                  const SizedBox(height: 16),
                ],
              );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Tempo readout',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  slider(
                    'Show tempo at confidence',
                    g.showAbove.toStringAsFixed(2),
                    'Higher waits for a clearer beat before showing a BPM '
                        'instead of "Listening…".',
                    g.showAbove,
                    _showAboveMin,
                    _showAboveMax,
                    9,
                    (x) => g.showAbove = x,
                  ),
                  slider(
                    'Hysteresis',
                    g.hysteresis.toStringAsFixed(2),
                    'Once showing, the tempo stays until confidence falls '
                        '${g.hysteresis.toStringAsFixed(2)} below that '
                        '(to ${g.hideBelow.toStringAsFixed(2)}).',
                    g.hysteresis,
                    0,
                    _hysteresisMax,
                    20,
                    (x) => g.hysteresis = x,
                  ),
                  slider(
                    'Hold before losing the tempo',
                    '${g.holdSeconds.toStringAsFixed(1)} s',
                    'After the beat goes weak or stops, keep showing the '
                        'last tempo this long.',
                    g.holdSeconds,
                    0,
                    _holdMax,
                    20,
                    (x) => g.holdSeconds = x,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => change(() {
                        g.showAbove = TempoDisplayGate.defaultShowAbove;
                        g.hysteresis = TempoDisplayGate.defaultHysteresis;
                        g.holdSeconds = TempoDisplayGate.defaultHoldSeconds;
                      }),
                      child: const Text('Reset to defaults'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
    
    // Another playlist was picked (or the show's was deleted): the show is over.
    if (_mode == _ScreenMode.show &&
        !identical(_playlists[_currentPlaylistIndex], _showPlaylist)) {
      _endShowMode();
    }
    if (_mode == _ScreenMode.show) {
      // Plays the working BPM, and only once the user presses play.
      final bpm = _showDraft.bpm;
      if (bpm == null) _isMetronomePlaying = false;
      _applyMetronomeBpm(bpm ?? 120);
      return;
    }

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
    if (_mode == _ScreenMode.setlist) {
      _tempoDetector.expectedBpm = targetBpm.toDouble();
      _centerPreferredRangeOn(targetBpm.toDouble());
    }
    _applyMetronomeBpm(targetBpm);
    _saveSetlistPosition();
  }

  void _applyMetronomeBpm(int bpm) {
    final msPerBeat = (60000 / bpm).round();
    _metronomeController.duration = Duration(milliseconds: msPerBeat);
    if (_isMetronomePlaying) {
      _metronomeController.repeat();
    } else {
      _metronomeController.stop();
      _metronomeController.reset();
    }
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
    if (_mode == _ScreenMode.show) {
      setState(() {
        _showDraft.nudge(delta);
        _syncShowHint();
        _updateMetronomeTempo();
      });
      return;
    }
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
        // A snackbar with an action stays up forever unless told otherwise.
        persist: false,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _setSongBpm(song, previous),
        ),
      ));
  }

  bool _canNudge(Playlist playlist) => _mode == _ScreenMode.show
      ? _showDraft.bpm != null
      : playlist.items.isNotEmpty;

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
                  !_canNudge(playlist) ? null : () => _nudgeCurrentSongBpm(d),
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

  /// Cancel a pending post-lock stop (the user or a song change took over).
  void _cancelLockStop() {
    _lockStopTimer?.cancel();
    _lockStopTimer = null;
  }

  void _toggleMetronome() {
    _cancelLockStop();
    // Starting the metronome is a count-in, just like changing song: watch
    // for the band to lock onto the target and pause it then. Stopping it
    // cancels the watch.
    final target = _currentTargetBpm;
    if (!_isMetronomePlaying && target != null) {
      _tempoLock.arm(target);
    } else {
      _tempoLock.disarm();
    }
    setState(() {
      _isMetronomePlaying = !_isMetronomePlaying;
      _updateMetronomeTempo();
    });
  }

  /// Switch free-running mode on or off. On: stop the metronome and the
  /// count-in lock, drop the song target, and weight detection toward the
  /// most common tempos. Off: back to the current song's target and range.
  void _setFreeRunning(bool on) {
    if (on && _mode == _ScreenMode.show) _setShowMode(false);
    _cancelLockStop();
    setState(() {
      _mode = on ? _ScreenMode.freeRunning : _ScreenMode.setlist;
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

  /// Enter or leave show creation mode. Entering starts a new, empty
  /// playlist for the show and listens wide with no target. Leaving keeps
  /// the playlist (unless nothing was added) and goes back to the setlist.
  void _setShowMode(bool on) {
    if (on == (_mode == _ScreenMode.show)) return;
    _cancelLockStop();
    if (on) {
      final playlist = Playlist(_uniquePlaylistName('New show'), []);
      setState(() {
        _playlists.add(playlist);
        _currentPlaylistIndex = _playlists.length - 1;
        _currentSetlistIndex = 0;
        _showPlaylist = playlist;
        _mode = _ScreenMode.show;
        _showDraft = ShowDraft(advance: _showDraft.advance);
        _tapTempo.reset();
        _tempoLock.disarm();
        _isMetronomePlaying = false;
        _driftTracker.reset();
        _drift = null;
        _tempoDetector.expectedBpm = null;
        _tempoDetector.setPreferredRange(
            _showTempoRange.start, _showTempoRange.end);
        _updateMetronomeTempo();
      });
      _savePlaylists();
      return;
    }
    final playlist = _showPlaylist;
    setState(_endShowMode);
    if (playlist != null && playlist.items.isEmpty && _playlists.length > 1) {
      _changePlaylists(() => _playlists.remove(playlist));
    } else {
      setState(_updateMetronomeTempo);
    }
  }

  /// Drop show state and go back to setlist mode. Doesn't call setState.
  void _endShowMode() {
    _mode = _ScreenMode.setlist;
    _showPlaylist = null;
    _showDraft.resetWorking();
    _tapTempo.reset();
    _isMetronomePlaying = false;
    _currentSetlistIndex = 0;
  }

  /// Point the detector at the working BPM so it listens in the octave the
  /// user chose (null before any capture, tap or nudge: no bias).
  void _syncShowHint() => _tempoDetector.expectedBpm = _showDraft.anchor;

  /// Set the working BPM from the heard tempo (scaled).
  void _showCapture() {
    if (_currentCalculatedBpm <= 0) return;
    setState(() {
      _showDraft.capture(_currentCalculatedBpm);
      _syncShowHint();
      _updateMetronomeTempo();
    });
  }

  void _showTap() {
    final bpm = _tapTempo.tap(_tapClock.elapsed);
    if (bpm == null) return;
    setState(() {
      _showDraft.setBpm(bpm);
      _syncShowHint();
      _updateMetronomeTempo();
    });
  }

  /// Append the working song to the show, with an Undo.
  void _commitShowSong() {
    final playlist = _showPlaylist;
    if (playlist == null) return;
    final label = _showDraft.pendingLabel, title = _showDraft.title;
    final song = _showDraft.commit();
    if (song == null) return;
    final item = SetlistItem(song.name, song.bpm);
    setState(() {
      playlist.items.add(item);
      _tapTempo.reset();
      _syncShowHint();
      _updateMetronomeTempo();
    });
    _savePlaylists();
    _showSnack('Added "${song.name}" at ${song.bpm} BPM', undo: () {
      setState(() {
        playlist.items.remove(item);
        _showDraft.setPendingLabel(label);
        _showDraft.title = title;
        _showDraft.setBpm(song.bpm.toDouble());
        _syncShowHint();
        _updateMetronomeTempo();
      });
      _savePlaylists();
    });
  }

  /// Edit the song's number and optional title; the song is named
  /// "1a. Title" (or just "1a" with no title).
  Future<void> _editShowLabel() async {
    final numberController = TextEditingController(text: _showDraft.pendingLabel);
    final titleController = TextEditingController(text: _showDraft.title);
    void done(BuildContext context) =>
        Navigator.pop(context, (numberController.text, titleController.text));
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Song'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: numberController,
              decoration: const InputDecoration(
                  labelText: 'Number', hintText: 'e.g. 7, 4c'),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Title (optional)', hintText: 'e.g. Blue Moon'),
              onSubmitted: (_) => done(context),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(onPressed: () => done(context), child: const Text('OK')),
        ],
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _showDraft.setPendingLabel(result.$1.trim());
        _showDraft.title = result.$2;
      });
    }
  }

  /// Move to song [index] of the current playlist and start its count-in:
  /// the metronome starts on beat 1, the detector listens afresh, and the
  /// metronome pauses once the band locks onto the song's marking.
  void _goToSong(int index) {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty) return;
    // Picking a song means playing to its target again.
    if (_mode == _ScreenMode.freeRunning) _setFreeRunning(false);
    _cancelLockStop();
    setState(() {
      _currentSetlistIndex = index.clamp(0, playlist.items.length - 1);
      _isMetronomePlaying = true;
      _metronomeController.reset();
      _updateMetronomeTempo();
      _tempoDetector.reset();
      _currentCalculatedBpm = 0;
      _displayGate.reset();
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
    if (_mode == _ScreenMode.show) return;
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
      _displayGate.reset();
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
      _currentCalculatedBpm = _displayGate.update(now, DateTime.now());
      final playlist = _playlists[_currentPlaylistIndex];
      _drift = playlist.items.isEmpty || _mode != _ScreenMode.setlist
          ? null
          : _driftTracker.update(_currentCalculatedBpm,
              playlist.items[_currentSetlistIndex].bpm.toDouble(),
              confidence: _displayGate.confidence);
    });

    if (_isMetronomePlaying &&
        _lockStopTimer == null &&
        _tempoLock.update(now, DateTime.now())) {
      // Locked on: let the metronome run a little longer, then stop it.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Locked on ${now!.bpm.toStringAsFixed(1)} BPM — '
            'metronome stops in ${_runOnAfterLock.inSeconds} s'),
        duration: _runOnAfterLock,
      ));
      _lockStopTimer = Timer(_runOnAfterLock, () {
        _lockStopTimer = null;
        if (!mounted || !_isMetronomePlaying) return;
        setState(() {
          _isMetronomePlaying = false;
          _updateMetronomeTempo();
        });
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chartTimer?.cancel();
    _lockStopTimer?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _midiSub?.cancel();
    _metronomeController.dispose();
    _bandLeader.removeListener(_onBandLeaderChanged);
    _bandLeader.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ==========================================================================
  // Band sync
  // ==========================================================================

  void _onBandLeaderChanged() {
    if (mounted) setState(() {});
  }

  /// What the leader broadcasts: polled a few times a second by
  /// [BandSyncLeader], which only re-advertises when something changed.
  BandSyncSnapshot _bandSyncSnapshot() {
    final playlist = _playlists[_currentPlaylistIndex];
    final details = BandSyncDetails(
        playlistName: playlist.name,
        songs: [for (final song in playlist.items) song.name],
        appVersion: _appVersion?.short);
    final hasSong = _mode == _ScreenMode.setlist && playlist.items.isNotEmpty;
    return (
      details: details,
      state: BandSyncState(
        sessionId: 0,
        metronomePlaying: _isMetronomePlaying,
        freeRunning: _mode != _ScreenMode.setlist,
        drift: _drift?.level,
        rushing: _drift?.isRushing ?? false,
        songIndex: hasSong ? _currentSetlistIndex : null,
        targetBpm: _currentTargetBpm,
        detectedBpm: _currentCalculatedBpm > 0 ? _currentCalculatedBpm : null,
        confidence: _isRecording ? _detectionConfidence : 0,
        detailsVersion: detailsVersionOf(details),
      ),
    );
  }

  Future<void> _toggleLeading() async {
    if (_bandLeader.isActive) {
      await _bandLeader.stop();
      _showSnack('Stopped leading the band');
      return;
    }
    if (_bandIcon == null) {
      _saveBandIcon(
          BandSyncIcon(math.Random().nextInt(bandSyncIconCount)));
    }
    final error = await _bandLeader.start(icon: _bandIcon);
    _showSnack(error ??
        'Leading the band as the ${_bandLeader.icon.name} — bandmates '
            'choose “Follow a leader”');
  }

  void _saveBandIcon(BandSyncIcon icon) {
    _bandIcon = icon;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt('bandIcon', icon.index));
  }

  Future<void> _chooseBandIcon() async {
    final current = _bandIcon ??
        (_bandLeader.isActive ? _bandLeader.icon : const BandSyncIcon(0));
    final icon = await showBandSyncIconPicker(context, current);
    if (icon == null || !mounted) return;
    setState(() => _saveBandIcon(icon));
    // A new icon needs a new session id: followers re-join.
    if (_bandLeader.isActive && _bandLeader.icon != icon) {
      await _bandLeader.stop();
      final error = await _bandLeader.start(icon: icon);
      _showSnack(error ??
          'Now leading as the ${icon.name} — bandmates need to re-join');
    }
  }

  /// Followers mirror the leader instead of listening themselves, so the
  /// mic, metronome and any broadcast stop while the follower screen is up.
  Future<void> _openFollower() async {
    if (_bandLeader.isActive) await _bandLeader.stop();
    final wasRecording = _isRecording;
    if (wasRecording) _stopRecording();
    if (_isMetronomePlaying) _toggleMetronome();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BandSyncFollowerScreen(appVersion: _appVersion)));
    if (wasRecording && mounted) _startRecording();
  }

  Widget _buildBandMenu() {
    final leading = _bandLeader.isActive;
    return PopupMenuButton<void Function()>(
      tooltip: 'Band sync',
      onSelected: (action) => action(),
      // Most bandmates follow, so that comes first.
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _openFollower,
          child: const ListTile(
            leading: Icon(Icons.groups),
            title: Text('Follow a leader…'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        CheckedPopupMenuItem(
          value: _toggleLeading,
          checked: leading,
          child: Text(leading
              ? 'Leading as ${_bandLeader.icon.name} (${_bandLeader.code})'
                  '${_bandLeader.joinedCount > 0 ? ' · ${_bandLeader.joinedCount} joined' : ''}'
              : 'Lead the band'),
        ),
        PopupMenuItem(
          value: _chooseBandIcon,
          child: ListTile(
            leading: _bandIcon == null
                ? const Icon(Icons.palette_outlined)
                : BandSyncIconBadge(_bandIcon!),
            title: const Text('Band icon…'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      // While leading, show the session icon so bandmates can check they
      // joined the right phone (the code is in the menu, for when two
      // nearby leaders happen to share an icon).
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: !leading
            ? const Icon(Icons.podcasts)
            : _bandLeader.error == null
                ? BandSyncIconBadge(_bandLeader.icon, size: 36)
                : const Icon(Icons.podcasts, color: Colors.redAccent),
      ),
    );
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
      subject: '${playlist.name} (Beth setlist)',
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
                    'Paste a setlist shared from Beth, or one song per '
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
    _addImportedPlaylists(result);
  }

  /// Append [result]'s playlists (renamed if a name is taken) and switch to
  /// the first of them.
  void _addImportedPlaylists(PlaylistImport result) {
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

  // ==========================================================================
  // Backup and restore (all playlists, to a file wherever the system's
  // pickers can reach: Files / iCloud Drive on iOS, Drive or the phone's
  // storage on Android)
  // ==========================================================================

  void _showBackupSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Back up all playlists'),
              subtitle: const Text('Save a file to the phone, Google Drive, iCloud Drive…'),
              onTap: () {
                Navigator.pop(context);
                _backUpPlaylists();
              },
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restore from a file'),
              subtitle: const Text('A backup, or a setlist shared as a file'),
              onTap: () {
                Navigator.pop(context);
                _restoreFromFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  static const MethodChannel _filesChannel = MethodChannel('beth/files');

  /// Saves a backup file. Android: the system "Save to…" picker (Downloads,
  /// Drive, …; see MainActivity). Elsewhere: the share sheet, whose "Save to
  /// Files" reaches iCloud Drive and the phone on iOS.
  Future<void> _backUpPlaylists() async {
    final now = DateTime.now();
    final name = backupFileName(now);
    final bytes =
        utf8.encode(playlistsToBackup(_playlists,
            savedAt: now, appVersion: _appVersion?.label));
    final n = _playlists.length;
    final saved = 'Backed up $n playlist${n == 1 ? '' : 's'}';
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final ok = await _filesChannel.invokeMethod<bool>('saveFile', {
          'name': name,
          'mimeType': 'application/json',
          'bytes': bytes,
        });
        if (ok == true && mounted) _showSnack('$saved to $name');
      } on PlatformException catch (e) {
        if (mounted) _showSnack('Couldn’t save the backup (${e.message})');
      }
      return;
    }
    final result = await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/json')],
      fileNameOverrides: [name],
      subject: name,
    ));
    if (!mounted) return;
    // Only confirm when the platform says a target was picked.
    if (result.status == ShareResultStatus.success) _showSnack(saved);
  }

  Future<void> _restoreFromFile() async {
    const types = XTypeGroup(
      label: 'Beth backups and setlists',
      extensions: ['json', 'txt'],
      mimeTypes: ['application/json', 'text/plain', 'application/octet-stream'],
      uniformTypeIdentifiers: ['public.json', 'public.plain-text'],
    );
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: const [types]);
    } catch (e) {
      _showSnack('Couldn’t open the file picker');
      return;
    }
    if (file == null || !mounted) return;
    final String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      if (mounted) _showSnack('Couldn’t read ${file.name}');
      return;
    }
    if (!mounted) return;
    final result = parsePlaylistText(text,
        fallbackName: file.name.replaceFirst(RegExp(r'\.[^.]*$'), ''));
    if (result.playlists.isEmpty) {
      _showSnack('No playlists found in ${file.name}');
      return;
    }

    final n = result.playlists.length;
    final songs = result.songCount;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.isBackup ? 'Restore backup?' : 'Import playlists?'),
        content: Text(
          '${file!.name}\n'
          '$n playlist${n == 1 ? '' : 's'}, $songs song${songs == 1 ? '' : 's'}\n\n'
          'Add ${n == 1 ? 'it' : 'them'} to your playlists, or replace all '
          'of your playlists?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            child: const Text('Replace all'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'add'),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'add':
        _addImportedPlaylists(result);
      case 'replace':
        _replacePlaylists(result.playlists);
    }
  }

  /// Swap in [playlists] for all of the current ones, with Undo.
  void _replacePlaylists(List<Playlist> playlists) {
    final old = _playlists;
    final oldPlaylist = _currentPlaylistIndex;
    final oldSong = _currentSetlistIndex;
    void show(List<Playlist> list, int playlist, int song) {
      setState(() {
        _playlists = list;
        _currentPlaylistIndex = playlist;
        _currentSetlistIndex = song;
        _updateMetronomeTempo();
      });
      _savePlaylists();
    }

    show(playlists, 0, 0);
    final n = playlists.length;
    _showSnack('Restored $n playlist${n == 1 ? '' : 's'}',
        undo: () => show(old, oldPlaylist, oldSong));
  }

  void _showSnack(String message, {VoidCallback? undo}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        persist: false,
        duration: const Duration(seconds: 4),
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
              leading: Icon(_mode == _ScreenMode.show
                  ? Icons.check
                  : Icons.playlist_add),
              title: Text(_mode == _ScreenMode.show
                  ? 'Done building show'
                  : 'Build a show'),
              onTap: () {
                Navigator.pop(context); // close drawer
                _setShowMode(_mode != _ScreenMode.show);
              },
            ),
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
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Tempo readout'),
              subtitle: const Text('Thresholds, hysteresis, hold'),
              onTap: () {
                Navigator.pop(context); // close drawer
                _showDetectionSettings();
              },
            ),
            ListTile(
              leading: const Icon(Icons.backup),
              title: const Text('Back up & restore'),
              onTap: () {
                Navigator.pop(context); // close drawer
                _showBackupSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About Beth'),
              subtitle: _appVersion == null ? null : Text(_appVersion!.label),
              onTap: () {
                Navigator.pop(context); // close drawer
                _showAbout();
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
  RangeValues get _bandRange => switch (_mode) {
        _ScreenMode.freeRunning => _commonTempoRange,
        _ScreenMode.show => _showTempoRange,
        _ScreenMode.setlist => _preferredRange,
      };

  double? get _currentTargetBpm {
    final playlist = _playlists[_currentPlaylistIndex];
    if (playlist.items.isEmpty || _mode != _ScreenMode.setlist) return null;
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
    // In show mode the half/double-time scale applies to what's shown.
    final scale = _mode == _ScreenMode.show ? _showDraft.scale : ShowScale.normal;
    final shownBpm = _mode == _ScreenMode.show
        ? _showDraft.shown(_currentCalculatedBpm)
        : _currentCalculatedBpm;
    final parts = shownBpm.toStringAsFixed(1).split('.');
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
                      if (scale != ShowScale.normal)
                        TextSpan(
                          text: scale == ShowScale.half ? ' ×½' : ' ×2',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.secondary),
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
        // The Beth mark opens the playlists drawer (in place of the
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
        title: Text(_mode == _ScreenMode.freeRunning ? 'Free running' : playlist.name,
            overflow: TextOverflow.ellipsis),
        actions: [
          _buildBandMenu(),
          IconButton(
            tooltip: _mode == _ScreenMode.freeRunning ? 'Back to setlist' : 'Free-running mode',
            icon: Icon(_mode == _ScreenMode.freeRunning ? Icons.close_fullscreen : Icons.open_in_full),
            onPressed: () => _setFreeRunning(_mode != _ScreenMode.freeRunning),
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
        child: _mode == _ScreenMode.freeRunning
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
          if (_mode == _ScreenMode.setlist)
            Row(
              children: [
                Text(
                  'Range ${_preferredRange.start.round()}–${_preferredRange.end.round()}',
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
    final show = _mode == _ScreenMode.show;
    final enabled = show ? _showDraft.bpm != null : playlist.items.isNotEmpty;
    return Semantics(
      button: true,
      label: _isMetronomePlaying ? 'Stop metronome' : 'Start metronome',
      child: GestureDetector(
        onTap: !enabled ? null : _toggleMetronome,
        child: AnimatedBuilder(
          animation: _pulseAnimation,
          builder: (context, child) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isMetronomePlaying && enabled
                    ? Theme.of(context).colorScheme.secondary
                        .withAlpha(((1.0 - _pulseAnimation.value) * 255).toInt())
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                boxShadow: [
                  if (_isMetronomePlaying && enabled)
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
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      show ? '${_showDraft.bpm ?? '—'}' : '${currentItem.bpm}',
                      style: TextStyle(
                        fontSize: size * 0.35,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
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
              if (currentItem.durationSeconds != null) ...[
                const SizedBox(height: 4),
                Text(
                  formatDuration(currentItem.durationSeconds!),
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
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
                    !_canNudge(playlist) ? null : () => _nudgeCurrentSongBpm(d),
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

  /// Show creation mode's bottom (portrait) / right (landscape) panel:
  /// working BPM on the metronome circle with nudges, the half/double-time
  /// scale, Capture and Tap, and the song number with Commit.
  Widget _buildShowControls(
      BuildContext context, Playlist playlist, SetlistItem currentItem,
      {bool landscape = false}) {
    final draft = _showDraft;
    final heard = _currentCalculatedBpm > 0;
    final label = draft.pendingLabel.trim();
    final duplicate = ShowDraft.isDuplicate(label, [for (final s in playlist.items) s.name]);

    final scaleSelector = SegmentedButton<ShowScale>(
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: ShowScale.half, label: Text('½')),
        ButtonSegment(value: ShowScale.normal, label: Text('1')),
        ButtonSegment(value: ShowScale.twice, label: Text('2')),
      ],
      selected: {draft.scale},
      // Tapping the active option arrives as an empty selection.
      onSelectionChanged: (s) => setState(() {
        draft.selectScale(s.isEmpty ? draft.scale : s.first);
        _syncShowHint();
      }),
    );

    final captureTap = Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: heard ? _showCapture : null,
          icon: const Icon(Icons.hearing),
          label: Text(heard
              ? 'Capture ${draft.scaled(_currentCalculatedBpm)}'
              : 'Capture'),
        ),
        OutlinedButton.icon(
          onPressed: _showTap,
          icon: const Icon(Icons.touch_app),
          label: const Text('Tap'),
        ),
      ],
    );

    final labelCommit = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        ActionChip(
          tooltip: 'Edit song number',
          avatar: duplicate
              ? const Icon(Icons.warning_amber, color: Colors.amber)
              : null,
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label.isEmpty
                  ? 'Number?'
                  : draft.title.isEmpty
                      ? 'Song $label'
                      : draft.pendingName,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          onPressed: _editShowLabel,
        ),
        FilledButton.icon(
          onPressed: draft.bpm == null || label.isEmpty ? null : _commitShowSong,
          icon: const Icon(Icons.add),
          label: const Text('Commit'),
        ),
      ],
    );

    Widget stepper(String name, VoidCallback down, VoidCallback up) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.outlined(
              tooltip: '$name down',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(down),
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 56,
              child: Text(name,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            ),
            IconButton.outlined(
              tooltip: '$name up',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(up),
              icon: const Icon(Icons.add),
            ),
          ],
        );

    // Adjust the number and letter before committing.
    final advanceRow = Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          children: [
            stepper('Number', () => draft.stepNumber(-1), () => draft.stepNumber(1)),
            stepper('Letter', () => draft.stepSuffix(-1), () => draft.stepSuffix(1)),
          ],
        ),
        Text(
          duplicate
              ? 'Already used'
              : '${playlist.items.length} song${playlist.items.length == 1 ? '' : 's'}',
          style: TextStyle(
              color: duplicate ? Colors.amber : Colors.grey[500], fontSize: 12),
        ),
      ],
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: SingleChildScrollView(
        child: landscape
            ? Row(
                children: [
                  _buildMetronomeCircle(context, playlist, currentItem, size: 112),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildNudgeRow(playlist),
                        const SizedBox(height: 8),
                        scaleSelector,
                        const SizedBox(height: 8),
                        captureTap,
                        const SizedBox(height: 8),
                        labelCommit,
                        const SizedBox(height: 4),
                        advanceRow,
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                children: [
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
                  scaleSelector,
                  const SizedBox(height: 12),
                  captureTap,
                  const SizedBox(height: 16),
                  labelCommit,
                  const SizedBox(height: 8),
                  advanceRow,
                ],
              ),
      ),
    );
  }

  /// Bottom (portrait) / right (landscape): metronome, song info and the
  /// pinned Previous/Next controls.
  Widget _buildControlsSection(
      BuildContext context, Playlist playlist, SetlistItem currentItem,
      {bool landscape = false}) {
    if (_mode == _ScreenMode.show) {
      return _buildShowControls(context, playlist, currentItem,
          landscape: landscape);
    }
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
                  subtitle: Text([
                    '${song.bpm} BPM',
                    if (song.durationSeconds != null)
                      formatDuration(song.durationSeconds!),
                  ].join(' · ')),
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
                              persist: false,
                              duration: const Duration(seconds: 4),
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
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: 'Length',
                            hintText: 'm:ss, optional',
                            errorText: durationError,
                          ),
                          keyboardType: TextInputType.datetime,
                          controller: durationController,
                        ),
                      ),
                    ],
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

                  setState(() {
                    if (currentSong == null) {
                      widget.playlist.items
                          .add(SetlistItem(name, bpm, durationSeconds: duration));
                    } else {
                      currentSong
                        ..name = name
                        ..bpm = bpm
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
