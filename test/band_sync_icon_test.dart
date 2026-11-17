import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:beth/band_sync_icon.dart';

void main() {
  test('96 icons, each with a distinct name', () {
    expect(bandSyncIconCount, 96);
    expect(bandSyncIconColourRgb.length, bandSyncIconColourNames.length);
    final names = {
      for (var i = 0; i < bandSyncIconCount; i++) BandSyncIcon(i).name,
    };
    expect(names.length, bandSyncIconCount);
  });

  test('shape and colour round-trip', () {
    for (var i = 0; i < bandSyncIconCount; i++) {
      final icon = BandSyncIcon(i);
      expect(BandSyncIcon.of(shape: icon.shape, colour: icon.colour), icon);
    }
    final icon = BandSyncIcon.of(shape: 1, colour: 3);
    expect(icon.name, 'orange anchor');
    expect(icon.rgb, 0xFF9100);
    // The default (index 0) is a plain one.
    expect(const BandSyncIcon(0).name, 'blue star');
  });

  test('icon comes from the session id', () {
    expect(BandSyncIcon.forSession(0).index, 0);
    expect(BandSyncIcon.forSession(95).index, 95);
    expect(BandSyncIcon.forSession(96).index, 0);
    expect(BandSyncIcon.forSession(0x4F2A).index, 0x4F2A % 96);
    expect(BandSyncIcon.forSession(0xFFFF).index, 0xFFFF % 96);
    expect(BandSyncIcon.forSession(0xFFFF).isValid, isTrue);
  });

  test('sessionIdForIcon gives a 16-bit id with that icon', () {
    final r = math.Random(1);
    for (var i = 0; i < bandSyncIconCount; i++) {
      final icon = BandSyncIcon(i);
      final ids = <int>{};
      for (var k = 0; k < 50; k++) {
        final id = sessionIdForIcon(icon, r);
        expect(id, inInclusiveRange(0, 0xFFFF));
        expect(BandSyncIcon.forSession(id), icon);
        ids.add(id);
      }
      // Still random: plenty of different ids per icon.
      expect(ids.length, greaterThan(30));
    }
  });

  test('sessionIdForIcon reaches the top of the range', () {
    // 0xFFFF % 96 == 63: the largest id for that icon is 0xFFFF itself.
    final icon = BandSyncIcon(0xFFFF % 96);
    final r = math.Random(2);
    var max = 0;
    for (var k = 0; k < 5000; k++) {
      max = math.max(max, sessionIdForIcon(icon, r));
    }
    expect(max, 0xFFFF);
  });
}
