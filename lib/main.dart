import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'playlist.dart';
import 'tempo_detector.dart';
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
    with SingleTickerProviderStateMixin {
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
    _tempoDetector.expectedBpm = targetBpm.toDouble();
    _centerPreferredRangeOn(targetBpm.toDouble());
    final msPerBeat = (60000 / targetBpm).round();
    _metronomeController.duration = Duration(milliseconds: msPerBeat);
    if (_isMetronomePlaying) {
      _metronomeController.repeat();
    } else {
      _metronomeController.stop();
      _metronomeController.reset();
    }
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

  void _advanceSetlist() {
    setState(() {
      final playlist = _playlists[_currentPlaylistIndex];
      if (playlist.items.isNotEmpty) {
        _currentSetlistIndex = (_currentSetlistIndex + 1) % playlist.items.length;
        _isMetronomePlaying = true; // Auto-play on next song
        _updateMetronomeTempo();
        // Listen fresh for the new song, and pause the metronome once the
        // band locks onto its marking.
        _tempoDetector.reset();
        _currentCalculatedBpm = 0;
        _tempoLock.arm(playlist.items[_currentSetlistIndex].bpm.toDouble());
      }
    });
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
    _chartTimer?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _midiSub?.cancel();
    _metronomeController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.teal),
            child: Center(
              child: Text('Playlists', style: TextStyle(color: Colors.white, fontSize: 24)),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _playlists.length,
              itemBuilder: (context, index) {
                final playlist = _playlists[index];
                return ListTile(
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.items.length} songs'),
                  selected: _currentPlaylistIndex == index,
                  onTap: () {
                    setState(() {
                      _currentPlaylistIndex = index;
                      _currentSetlistIndex = 0;
                      _updateMetronomeTempo();
                    });
                    Navigator.pop(context);
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () {
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
                        },
                      ),
                      if (_playlists.length > 1) // Only allow delete if it's not the last playlist
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                          onPressed: () {
                            setState(() {
                              _playlists.removeAt(index);
                              if (_currentPlaylistIndex >= index && _currentPlaylistIndex > 0) {
                                _currentPlaylistIndex--;
                              }
                              _currentSetlistIndex = 0;
                              _updateMetronomeTempo();
                            });
                            _savePlaylists();
                          },
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
          const SizedBox(height: 24),
        ],
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
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: _preferredRange.start,
              y2: _preferredRange.end,
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
            ? Text.rich(
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
                style: const TextStyle(color: Colors.white, shadows: shadow),
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
        title: Text('Metronome - ${playlist.name}'),
        actions: [
          IconButton(
            icon: Icon(_isRecording ? Icons.mic : Icons.mic_off),
            color: _isRecording ? Colors.redAccent : Colors.grey,
            onPressed: () {
              if (_isRecording) {
                _audioStreamSub?.cancel();
                _audioRecorder.stop();
                WakelockPlus.disable();
                setState(() {
                  _isRecording = false;
                  _currentCalculatedBpm = 0;
                });
              } else {
                _startRecording();
              }
            },
          )
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          // Top: BPM Graph
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
            ),
          ),
          
          const Divider(height: 1, thickness: 2),

          // Bottom: Metronome & Setlist
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Pulse Indicator, flanked by tempo nudge buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildNudgeColumn(playlist, const [-1, -5]),
                        const SizedBox(width: 16),
                        // The circle is also the play/stop button.
                        Semantics(
                          button: true,
                          label: _isMetronomePlaying ? 'Stop metronome' : 'Start metronome',
                          child: GestureDetector(
                            onTap: playlist.items.isEmpty ? null : _toggleMetronome,
                            child: AnimatedBuilder(
                              animation: _pulseAnimation,
                              builder: (context, child) {
                                return Container(
                                  width: 150,
                                  height: 150,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _isMetronomePlaying && playlist.items.isNotEmpty
                                        ? Theme.of(context).colorScheme.secondary.withAlpha(((1.0 - _pulseAnimation.value) * 255).toInt())
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
                                      const SizedBox(height: 28),
                                      Text(
                                        '${currentItem.bpm}',
                                        style: const TextStyle(
                                          fontSize: 48,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                      Icon(
                                        _isMetronomePlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                                        size: 28,
                                        color: _isMetronomePlaying ? Colors.redAccent : Colors.greenAccent,
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        _buildNudgeColumn(playlist, const [1, 5]),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Capture the heard tempo
                    FilledButton.tonalIcon(
                      onPressed: playlist.items.isEmpty || _currentCalculatedBpm <= 0
                          ? null
                          : _captureDetectedBpm,
                      icon: const Icon(Icons.hearing),
                      label: Text(_currentCalculatedBpm > 0
                          ? 'Capture ${_currentCalculatedBpm.round()}'
                          : 'Capture'),
                    ),

                    const SizedBox(height: 24),
                    
                    // Setlist Info
                    Text(
                      'CURRENT',
                      style: TextStyle(
                        color: Colors.grey[400],
                        letterSpacing: 2,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentItem.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    
                    const SizedBox(height: 32),
                    
                    // Controls
                    ElevatedButton.icon(
                      onPressed: playlist.items.isEmpty ? null : _advanceSetlist,
                      icon: const Icon(Icons.skip_next, size: 32),
                      label: const Text(
                        'NEXT SONG',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'MIDI trigger active (Any CC/Note)',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
                  subtitle: Text('${song.bpm} BPM'),
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
                          setState(() {
                            widget.playlist.items.removeAt(index);
                            widget.onChanged();
                          });
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
    final bpmController = TextEditingController(text: currentSong?.bpm.toString() ?? '120');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(currentSong == null ? 'Add Song' : 'Edit Song'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                decoration: const InputDecoration(labelText: 'Song Name'),
                controller: nameController,
                autofocus: true,
              ),
              TextField(
                decoration: const InputDecoration(labelText: 'BPM'),
                keyboardType: TextInputType.number,
                controller: bpmController,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final bpm = int.tryParse(bpmController.text) ?? 120;
                var name = nameController.text.trim();
                if (name.isEmpty) name = 'Unnamed Song';

                setState(() {
                  if (currentSong == null) {
                    widget.playlist.items.add(SetlistItem(name, bpm));
                  } else {
                    currentSong.name = name;
                    currentSong.bpm = bpm;
                  }
                  widget.onChanged();
                });
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
}
