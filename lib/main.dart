import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

void main() {
  runApp(const BpmMetronomeApp());
}

class BpmMetronomeApp extends StatelessWidget {
  const BpmMetronomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BPM Metronome',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.teal,
        useMaterial3: true,
      ),
      home: const MetronomeScreen(),
    );
  }
}

class SetlistItem {
  final String name;
  final int bpm;

  SetlistItem(this.name, this.bpm);
}

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen>
    with SingleTickerProviderStateMixin {
  // Setlist State
  final List<SetlistItem> _setlist = [
    SetlistItem('Song 1 (Slow)', 80),
    SetlistItem('Song 2 (Upbeat)', 120),
    SetlistItem('Song 3 (Fast)', 160),
    SetlistItem('Song 4 (Groove)', 105),
  ];
  int _currentSetlistIndex = 0;

  // Visual Metronome
  late AnimationController _metronomeController;
  late Animation<double> _pulseAnimation;
  bool _isMetronomePlaying = true;

  // Audio Recording & BPM Detection
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioStreamSub;
  bool _isRecording = false;

  // Chart Data
  final List<FlSpot> _bpmHistory = [];
  final double _historyWindowSeconds = 300; // 5 minutes
  int _timeCounterMs = 0;
  Timer? _chartTimer;
  double _currentCalculatedBpm = 0;

  // BPM Math State
  final List<double> _energyHistory = [];
  final List<int> _peakTimesMs = [];
  int _audioSamplesProcessed = 0;
  final int _sampleRate = 44100;

  // MIDI
  final MidiCommand _midiCommand = MidiCommand();
  StreamSubscription<MidiPacket>? _midiSub;

  @override
  void initState() {
    super.initState();
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

        // Keep only last 5 minutes
        if (_bpmHistory.length > _historyWindowSeconds) {
          _bpmHistory.removeAt(0);
        }
      });
    });
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
    final targetBpm = _setlist[_currentSetlistIndex].bpm;
    final msPerBeat = (60000 / targetBpm).round();
    _metronomeController.duration = Duration(milliseconds: msPerBeat);
    if (_isMetronomePlaying) {
      _metronomeController.repeat();
    } else {
      _metronomeController.stop();
      _metronomeController.reset();
    }
  }

  void _toggleMetronome() {
    setState(() {
      _isMetronomePlaying = !_isMetronomePlaying;
      _updateMetronomeTempo();
    });
  }

  void _advanceSetlist() {
    setState(() {
      _currentSetlistIndex = (_currentSetlistIndex + 1) % _setlist.length;
      _isMetronomePlaying = true; // Auto-play on next song
      _updateMetronomeTempo();
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
          // A real app might filter by specific CC or Note value.
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
        sampleRate: 44100,
        numChannels: 1,
      ));

      setState(() => _isRecording = true);

      _audioStreamSub = stream.listen((Uint8List data) {
        _processAudioBuffer(data);
      });
    }
  }

  void _processAudioBuffer(Uint8List data) {
    // Convert bytes to 16-bit PCM
    final Int16List pcmData = data.buffer.asInt16List();

    // Calculate RMS energy of this chunk
    double sumSquares = 0;
    for (int i = 0; i < pcmData.length; i++) {
      final sample = pcmData[i] / 32768.0; // Normalize
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / pcmData.length);

    _energyHistory.add(rms);
    if (_energyHistory.length > 50) {
      // Keep a small rolling window of energy (approx ~2 seconds of chunks)
      _energyHistory.removeAt(0);
    }

    _audioSamplesProcessed += pcmData.length;
    final currentMs = (_audioSamplesProcessed / _sampleRate * 1000).round();

    // Simple Peak Detection logic
    if (_energyHistory.length > 3) {
      final prevPrevRms = _energyHistory[_energyHistory.length - 4];
      final prevRms = _energyHistory[_energyHistory.length - 3];
      final currentRms = _energyHistory[_energyHistory.length - 2];
      
      // Calculate dynamic threshold
      double mean = _energyHistory.reduce((a, b) => a + b) / _energyHistory.length;
      double threshold = mean * 1.5 + 0.01; 

      if (prevRms > threshold &&
          prevRms > currentRms &&
          prevRms > prevPrevRms) {
        // We found a peak!
        _peakTimesMs.add(currentMs);

        // Keep last 10 seconds of peaks
        _peakTimesMs.removeWhere((t) => currentMs - t > 10000);

        _calculateBpmFromPeaks();
      }
    }
  }

  void _calculateBpmFromPeaks() {
    if (_peakTimesMs.length < 4) return;

    List<int> intervals = [];
    for (int i = 1; i < _peakTimesMs.length; i++) {
      intervals.add(_peakTimesMs[i] - _peakTimesMs[i - 1]);
    }

    // Filter reasonable beat intervals (40 to 220 BPM)
    // 60000 / 220 = 272ms, 60000 / 40 = 1500ms
    intervals = intervals
        .where((interval) => interval >= 272 && interval <= 1500)
        .toList();

    if (intervals.isEmpty) return;

    // Use median interval to avoid outliers
    intervals.sort();
    final medianInterval = intervals[intervals.length ~/ 2];
    
    final bpm = 60000 / medianInterval;
    
    if (bpm >= 40 && bpm <= 250) {
       _currentCalculatedBpm = _currentCalculatedBpm * 0.7 + bpm * 0.3; // Smoothing
    }
  }

  @override
  void dispose() {
    _chartTimer?.cancel();
    _audioStreamSub?.cancel();
    _audioRecorder.dispose();
    _midiSub?.cancel();
    _metronomeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = _setlist[_currentSetlistIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('BPM Metronome'),
        actions: [
          IconButton(
            icon: Icon(_isRecording ? Icons.mic : Icons.mic_off),
            color: _isRecording ? Colors.redAccent : Colors.grey,
            onPressed: () {
              if (_isRecording) {
                _audioStreamSub?.cancel();
                setState(() => _isRecording = false);
              } else {
                _startRecording();
              }
            },
          )
        ],
      ),
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
                  Text(
                    'Detected Tempo: ${_currentCalculatedBpm.toStringAsFixed(1)} BPM',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _bpmHistory.isEmpty
                        ? const Center(child: Text("Waiting for audio..."))
                        : LineChart(
                            LineChartData(
                              gridData: FlGridData(show: true),
                              titlesData: FlTitlesData(
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 40,
                                  ),
                                ),
                                topTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                rightTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                              ),
                              borderData: FlBorderData(show: true),
                              minY: 40,
                              maxY: 220,
                              minX: (_timeCounterMs / 1000.0) - _historyWindowSeconds,
                              maxX: _timeCounterMs / 1000.0,
                              lineBarsData: [
                                LineChartBarData(
                                  spots: _bpmHistory,
                                  isCurved: true,
                                  color: Theme.of(context).colorScheme.primary,
                                  barWidth: 3,
                                  isStrokeCapRound: true,
                                  dotData: FlDotData(show: false),
                                  belowBarData: BarAreaData(
                                    show: true,
                                    color: Theme.of(context).colorScheme.primary.withAlpha(51),
                                  ),
                                ),
                              ],
                            ),
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
                  // Pulse Indicator
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // To keep it centered, we can add a spacer or just let the Row align center
                      const SizedBox(width: 48), // Balance the icon button width
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isMetronomePlaying
                                  ? Theme.of(context).colorScheme.secondary.withAlpha(((1.0 - _pulseAnimation.value) * 255).toInt())
                                  : Theme.of(context).colorScheme.surfaceContainerHighest,
                              boxShadow: [
                                if (_isMetronomePlaying)
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
                            child: Center(
                              child: Text(
                                '${currentItem.bpm}',
                                style: const TextStyle(
                                  fontSize: 48,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        iconSize: 32,
                        icon: Icon(_isMetronomePlaying ? Icons.stop_circle_outlined : Icons.play_circle_fill),
                        color: _isMetronomePlaying ? Colors.redAccent : Colors.greenAccent,
                        onPressed: _toggleMetronome,
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 48),
                  
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
                    onPressed: _advanceSetlist,
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
