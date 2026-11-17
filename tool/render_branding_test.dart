// Renders the Beth icon and splash artwork to assets/branding/.
//
// It's written as a test so it can use Flutter's canvas without a device:
//
//   flutter test tool/render_branding_test.dart
//   dart run flutter_launcher_icons
//   dart run flutter_native_splash:create
//
// It also writes the CYD follower's copy of the mark
// (firmware/cyd-follower/src/branding_images.h).
//
// The mark: a pulse ring (the metronome), a beat waveform across it (the
// listening), and a sparkle (the wizard).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const background = Color(0xFF1E1846); // also used for adaptive bg + splash
const bgTop = Color(0xFF2E2468);
const bgBottom = Color(0xFF120E2E);
const lavender = Color(0xFFCFBCFF);
const amber = Color(0xFFFFD180);
const white = Color(0xFFFFFFFF);

const outDir = 'assets/branding';

/// Draws the mark centred at [c] with ring radius [u]. Everything stays
/// within ~1.36u of the centre. [mono] draws it all in one colour (Android
/// themed icons).
void drawMark(Canvas canvas, Offset c, double u, {Color? mono}) {
  Color col(Color x, [double alpha = 1]) =>
      (mono ?? x).withValues(alpha: alpha);

  // Echo ring: the pulse spreading out.
  canvas.drawCircle(
      c,
      u * 1.18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.06
        ..color = col(lavender, mono == null ? 0.35 : 0.6));

  // Main ring.
  canvas.drawCircle(
      c,
      u,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.11
        ..color = col(lavender));

  // Beat waveform: flat, a sharp onset spike, settle, flat.
  const pts = [
    Offset(-0.70, 0),
    Offset(-0.34, 0),
    Offset(-0.18, -0.52),
    Offset(-0.01, 0.44),
    Offset(0.13, -0.22),
    Offset(0.24, 0),
    Offset(0.70, 0),
  ];
  final wave = Path()..moveTo(c.dx + pts[0].dx * u, c.dy + pts[0].dy * u);
  for (final p in pts.skip(1)) {
    wave.lineTo(c.dx + p.dx * u, c.dy + p.dy * u);
  }
  canvas.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = col(white));

  // Sparkles.
  void sparkle(Offset at, double outer, double inner, Color color) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final r = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / 4;
      final pt = at + Offset(math.cos(a) * r, math.sin(a) * r);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = col(color));
  }

  sparkle(c + Offset(0.80 * u, -0.80 * u), 0.27 * u, 0.07 * u, amber);
  sparkle(c + Offset(1.08 * u, -0.40 * u), 0.10 * u, 0.03 * u, amber);
}

Future<void> render(String name, int size,
    void Function(Canvas canvas, double s) paint) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  paint(canvas, size.toDouble());
  final img = await rec.endRecording().toImage(size, size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File('$outDir/$name')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

/// The CYD follower's screen background (kBg in its display.cpp).
const cydBackground = Color(0xFF121018);

/// The mark on the CYD background at [alpha], as raw RGBA.
Future<Uint8List> renderCydMark(int size, double alpha) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final s = size.toDouble();
  final rect = Rect.fromLTWH(0, 0, s, s);
  canvas.drawRect(rect, Paint()..color = cydBackground);
  canvas.saveLayer(rect, Paint()..color = white.withValues(alpha: alpha));
  // The mark (and its sparkle) stays within ~1.36u of the centre.
  drawMark(canvas, Offset(s / 2, s / 2), s * 0.355);
  canvas.restore();
  final img = await rec.endRecording().toImage(size, size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bytes!.buffer.asUint8List();
}

/// RGBA as run-length encoded RGB565: (count, colour) pairs, runs never
/// crossing a row, so the firmware can draw it a row at a time with
/// horizontal lines and skip runs of background.
List<int> rle565(Uint8List rgba, int size) {
  final out = <int>[];
  for (var y = 0; y < size; y++) {
    int? colour;
    var count = 0;
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      final c = ((rgba[i] & 0xF8) << 8) |
          ((rgba[i + 1] & 0xFC) << 3) |
          (rgba[i + 2] >> 3);
      if (c == colour) {
        count++;
      } else {
        if (colour != null) out.addAll([count, colour]);
        colour = c;
        count = 1;
      }
    }
    out.addAll([count, colour!]);
  }
  return out;
}

String cArray(String name, List<int> values) {
  final b = StringBuffer('static const uint16_t $name[] = {\n');
  for (var i = 0; i < values.length; i += 12) {
    final row = values.skip(i).take(12);
    b.writeln('    ${row.map((v) => '0x${v.toRadixString(16).padLeft(4, '0')}').join(', ')},');
  }
  b.writeln('};');
  return b.toString();
}

Future<void> writeCydImages() async {
  final bg = ((cydBackground.r * 255).round() & 0xF8) << 8 |
      ((cydBackground.g * 255).round() & 0xFC) << 3 |
      (cydBackground.b * 255).round() >> 3;
  final b = StringBuffer()
    ..writeln('// Generated by tool/render_branding_test.dart. Do not edit.')
    ..writeln('// The Beth mark on the follower screen background,')
    ..writeln('// run-length encoded RGB565: (count, colour) pairs per row.')
    ..writeln('#pragma once')
    ..writeln()
    ..writeln('#include <stdint.h>')
    ..writeln()
    ..writeln('constexpr uint16_t kBrandingBackground = 0x${bg.toRadixString(16)};')
    ..writeln();
  for (final (name, size, alpha) in [
    ('kLogo', 96, 1.0),
    ('kLogoFaint', 216, 0.11),
  ]) {
    final runs = rle565(await renderCydMark(size, alpha), size);
    b
      ..writeln('constexpr int ${name}Size = $size;')
      ..writeln('constexpr int ${name}Length = ${runs.length};')
      ..write(cArray(name, runs))
      ..writeln();
  }
  File('firmware/cyd-follower/src/branding_images.h')
      .writeAsStringSync(b.toString());
}

void main() {
  test('render branding assets', () async {
    // Full icon (iOS, macOS, web, legacy Android): gradient square.
    await render('icon.png', 1024, (canvas, s) {
      canvas.drawRect(
          Rect.fromLTWH(0, 0, s, s),
          Paint()
            ..shader = ui.Gradient.linear(
                Offset.zero, Offset(s, s), [bgTop, bgBottom]));
      drawMark(canvas, Offset(s / 2, s / 2), s * 0.31);
    });

    // Android adaptive foreground: transparent. flutter_launcher_icons
    // insets it by 16% per side (scale 0.68), so draw it larger here; after
    // the inset the mark spans ~58% of the layer, inside the launcher safe
    // zone so no mask shape clips it.
    await render('icon_foreground.png', 1024, (canvas, s) {
      drawMark(canvas, Offset(s / 2, s / 2), s * 0.315);
    });

    // Android 13+ themed icon: single-colour silhouette, same geometry.
    await render('icon_monochrome.png', 1024, (canvas, s) {
      drawMark(canvas, Offset(s / 2, s / 2), s * 0.315, mono: white);
    });

    // Splash mark (treated as 4x: 768 px -> 192 dp).
    await render('splash.png', 768, (canvas, s) {
      drawMark(canvas, Offset(s / 2, s / 2), s * 0.25);
    });

    // Android 12+ splash: 1152 px canvas, visible circle is the middle
    // 768 px, so keep the mark within radius ~384.
    await render('splash_android12.png', 1152, (canvas, s) {
      drawMark(canvas, Offset(s / 2, s / 2), s * 0.205);
    });

    await writeCydImages();
  });
}
