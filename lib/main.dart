import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String name;
  int bpm;

  SetlistItem(this.name, this.bpm);

  Map<String, dynamic> toJson() => {
        'name': name,
        'bpm': bpm,
      };

  factory SetlistItem.fromJson(Map<String, dynamic> json) {
    return SetlistItem(
      json['name'] as String,
      json['bpm'] as int,
    );
  }
}

class Playlist {
  String name;
  List<SetlistItem> items;

  Playlist(this.name, this.items);

  Map<String, dynamic> toJson() => {
        'name': name,
        'items': items.map((item) => item.toJson()).toList(),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      json['name'] as String,
      (json['items'] as List<dynamic>)
          .map((item) => SetlistItem.fromJson(item as Map<String, dynamic>))
          .toList(),
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
  List<Playlist> _playlists = [
    Playlist('Default Setlist', [
      SetlistItem('Song 1 (Slow)', 80),
      SetlistItem('Song 2 (Upbeat)', 120),
      SetlistItem('Song 3 (Fast)', 160),
      SetlistItem('Song 4 (Groove)', 105),
    ]),
  ];
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

        // Keep only last 5 minutes
        if (_bpmHistory.length > _historyWindowSeconds) {
          _bpmHistory.removeAt(0);
        }
      });
    });
  }

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String? playlistsJson = prefs.getString('playlists');
    
    if (playlistsJson != null) {
      try {
        final List<dynamic> decodedList = jsonDecode(playlistsJson);
        setState(() {
          _playlists = decodedList
              .map((item) => Playlist.fromJson(item as Map<String, dynamic>))
              .toList();
        });
      } catch (e) {
        // If decoding fails, fallback to default
        debugPrint("Error loading playlists: \$e");
      }
    }
    
    setState(() {
      _isLoadingPlaylists = false;
    });
    _updateMetronomeTempo();
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String encodedList = jsonEncode(_playlists.map((p) => p.toJson()).toList());
    await prefs.setString('playlists', encodedList);
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
      final playlist = _playlists[_currentPlaylistIndex];
      if (playlist.items.isNotEmpty) {
        _currentSetlistIndex = (_currentSetlistIndex + 1) % playlist.items.length;
        _isMetronomePlaying = true; // Auto-play on next song
        _updateMetronomeTempo();
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
                                  setState(() {});
                                  _updateMetronomeTempo();
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
                setState(() => _isRecording = false);
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
                        const SizedBox(width: 48), // Balance the icon button width
                        AnimatedBuilder(
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
                          onPressed: playlist.items.isEmpty ? null : _toggleMetronome,
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
