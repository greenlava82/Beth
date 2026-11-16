import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:scbeatwiz/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Setup Mock SharedPreferences
    SharedPreferences.setMockInitialValues({});

    // Build our app and trigger a frame.
    await tester.pumpWidget(const SCBeatWizApp());
    await tester.pump(const Duration(seconds: 1));

    // Verify that our title is present.
    expect(find.text('Default Setlist'), findsOneWidget);
    // The logo is the button that opens the playlists drawer.
    expect(find.byTooltip('Playlists'), findsOneWidget);
    
    // Verify that the first setlist item is present.
    expect(find.text('Song 1 (Slow)'), findsOneWidget);
  });
}