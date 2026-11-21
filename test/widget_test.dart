import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beth/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Setup Mock SharedPreferences
    SharedPreferences.setMockInitialValues({});

    // Build our app and trigger a frame.
    await tester.pumpWidget(const BethApp());
    await tester.pump(const Duration(seconds: 1));

    // Verify that our title is present.
    expect(find.text('Default Setlist'), findsOneWidget);
    // The logo is the button that opens the playlists drawer.
    expect(find.byTooltip('Playlists'), findsOneWidget);
    
    // Verify that the first setlist item is present.
    expect(find.text('Song 1 (Slow)'), findsOneWidget);
  });

  testWidgets('Show creation: tap tempo, commit, undo', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const BethApp());
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Build a show'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('New show'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
    // Nothing to commit until there's a BPM.
    final commit = find.ancestor(
        of: find.text('Commit'), matching: find.bySubtype<ButtonStyleButton>());
    expect(tester.widget<ButtonStyleButton>(commit).onPressed, isNull);

    // Two quick taps (tap tempo reads the real clock, so this reads as a
    // very fast tempo, clamped to 300) give a working BPM.
    await tester.tap(find.text('Tap'));
    await tester.pump();
    await tester.tap(find.text('Tap'));
    await tester.pump();
    expect(find.text('300'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(commit).onPressed, isNotNull);

    await tester.tap(find.text('Commit'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Song 2'), findsOneWidget);
    expect(find.textContaining(RegExp(r'Added "1" at 300 BPM')), findsOneWidget);

    // (Tapping the action is obscured in the 800x600 test view.)
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Song 1'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(commit).onPressed, isNotNull);

    // Finishing with nothing committed drops the empty show.
    await tester.tap(find.byTooltip('Done building show'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Default Setlist'), findsOneWidget);
  });
}
