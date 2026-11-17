// Session icons for band sync: a shape and a colour derived from the
// leader's session id, so bandmates can check at a glance across a stage
// that they joined the right leader ("the orange anchor").
//
// Pure Dart (no Flutter imports). The mapping is part of the wire format in
// effect: followers derive the icon from the session id they already
// receive, and firmware/cyd-follower ports it (see band_sync_vectors.h).
import 'dart:math' as math;

/// The 16 shapes, in index order. Picked for distinct silhouettes at a
/// distance; drawn from Material icons of the same names.
const List<String> bandSyncIconShapes = [
  'star',
  'anchor',
  'heart',
  'bolt',
  'moon',
  'sun',
  'cloud',
  'key',
  'flame',
  'leaf',
  'paw',
  'rocket',
  'umbrella',
  'bell',
  'diamond',
  'drop',
];

/// The 6 colours, in index order, with their RGB values (bright, for a dark
/// background).
const List<String> bandSyncIconColourNames = [
  'blue',
  'green',
  'yellow',
  'orange',
  'pink',
  'red',
];

const List<int> bandSyncIconColourRgb = [
  0x40C4FF,
  0x00E676,
  0xFFEA00,
  0xFF9100,
  0xE040FB,
  0xFF5252,
];

/// Number of distinct icons (shape × colour).
final int bandSyncIconCount =
    bandSyncIconShapes.length * bandSyncIconColourNames.length;

/// A session icon: [index] is 0..[bandSyncIconCount) — shape in the low
/// part (index % 16), colour above it (index ~/ 16).
class BandSyncIcon {
  const BandSyncIcon(this.index);

  /// The icon a leader with [sessionId] shows.
  factory BandSyncIcon.forSession(int sessionId) =>
      BandSyncIcon((sessionId & 0xFFFF) % bandSyncIconCount);

  factory BandSyncIcon.of({required int shape, required int colour}) =>
      BandSyncIcon(colour * bandSyncIconShapes.length + shape);

  final int index;

  int get shape => index % bandSyncIconShapes.length;
  int get colour => index ~/ bandSyncIconShapes.length;

  String get shapeName => bandSyncIconShapes[shape];
  String get colourName => bandSyncIconColourNames[colour];
  int get rgb => bandSyncIconColourRgb[colour];

  /// What to call it out loud: "orange anchor".
  String get name => '$colourName $shapeName';

  bool get isValid => index >= 0 && index < bandSyncIconCount;

  @override
  bool operator ==(Object other) =>
      other is BandSyncIcon && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'BandSyncIcon($index, $name)';
}

/// A random session id whose icon is [icon], so a band keeps its icon from
/// gig to gig while each session still gets a fresh id.
int sessionIdForIcon(BandSyncIcon icon, [math.Random? random]) {
  final r = random ?? math.Random();
  // Ids 0..65535 with id % count == icon.index.
  final choices = (0x10000 - 1 - icon.index) ~/ bandSyncIconCount + 1;
  return icon.index + bandSyncIconCount * r.nextInt(choices);
}
