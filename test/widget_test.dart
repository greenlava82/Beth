import 'package:flutter_test/flutter_test.dart';

import 'package:bpm_metronome/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const BpmMetronomeApp());

    // Verify that our title is present.
    expect(find.text('Metronome - Default Setlist'), findsOneWidget);
    
    // Verify that the first setlist item is present.
    expect(find.text('Song 1 (Slow)'), findsOneWidget);
  });
}