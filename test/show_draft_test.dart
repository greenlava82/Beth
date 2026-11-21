import 'package:flutter_test/flutter_test.dart';
import 'package:beth/show_draft.dart';

void main() {
  test('capture overwrites and rounds', () {
    final d = ShowDraft();
    d.capture(120.4);
    expect(d.bpm, 120);
    d.capture(98.6);
    expect(d.bpm, 99);
  });

  test('scale applies to captures and persists across them', () {
    final d = ShowDraft();
    d.selectScale(ShowScale.half);
    d.capture(140);
    expect(d.bpm, 70);
    d.capture(142);
    expect(d.bpm, 71);
    expect(d.scaled(100), 50);
  });

  test('tapping the active option resets to 1; options do not stack', () {
    final d = ShowDraft();
    d.selectScale(ShowScale.half);
    d.selectScale(ShowScale.half);
    expect(d.scale, ShowScale.normal);
    d.selectScale(ShowScale.half);
    d.selectScale(ShowScale.twice);
    expect(d.scale, ShowScale.twice);
    d.selectScale(ShowScale.normal);
    expect(d.scale, ShowScale.normal);
  });

  test('tap and nudge ignore the scale', () {
    final d = ShowDraft();
    d.selectScale(ShowScale.twice);
    d.setBpm(100);
    expect(d.bpm, 100);
    d.nudge(5);
    expect(d.bpm, 105);
    d.nudge(-1);
    expect(d.bpm, 104);
  });

  test('nudge before any BPM is a no-op', () {
    final d = ShowDraft()..nudge(5);
    expect(d.bpm, isNull);
  });

  test('clamps to 30..300', () {
    final d = ShowDraft();
    d.selectScale(ShowScale.twice);
    d.capture(200);
    expect(d.bpm, 300);
    d.setBpm(10);
    expect(d.bpm, 30);
    d.nudge(-5);
    expect(d.bpm, 30);
  });

  test('commit returns the song and clears bpm and scale', () {
    final d = ShowDraft();
    d.selectScale(ShowScale.half);
    d.capture(140);
    final song = d.commit();
    expect(song, (name: '1', bpm: 70));
    expect(d.bpm, isNull);
    expect(d.scale, ShowScale.normal);
  });

  test('commit needs a bpm and a label', () {
    final d = ShowDraft();
    expect(d.commit(), isNull);
    d.setBpm(100);
    d.setPendingLabel('  ');
    expect(d.commit(), isNull);
    expect(d.bpm, 100);
  });

  test('whole auto-advance', () {
    final d = ShowDraft(pendingLabel: '3')..setBpm(100);
    d.commit();
    expect(d.pendingLabel, '4');
    d.setPendingLabel('4b');
    d.setBpm(100);
    d.commit();
    expect(d.pendingLabel, '5');
  });

  test('sub auto-advance', () {
    final d = ShowDraft(pendingLabel: '3', advance: ShowAdvance.sub);
    d.setBpm(100);
    d.commit();
    expect(d.pendingLabel, '3a');
    d.setBpm(100);
    d.commit();
    expect(d.pendingLabel, '3b');
  });

  test('manual edit sets the base', () {
    final d = ShowDraft()..setPendingLabel('7');
    d.setBpm(90);
    d.commit();
    expect(d.pendingLabel, '8');
  });

  test('free-text label commits and the sequence carries on', () {
    final d = ShowDraft(pendingLabel: '2');
    d.setPendingLabel('intro');
    d.setBpm(90);
    expect(d.commit(), (name: 'intro', bpm: 90));
    expect(d.pendingLabel, '2');
  });

  test('duplicate detection', () {
    expect(ShowDraft.isDuplicate('2A', ['1', '2a']), isTrue);
    expect(ShowDraft.isDuplicate('3', ['1', '2a']), isFalse);
    expect(ShowDraft.isDuplicate('', ['']), isFalse);
  });

  test('resetWorking keeps the label', () {
    final d = ShowDraft(pendingLabel: '5')..setBpm(90);
    d.selectScale(ShowScale.half);
    d.resetWorking();
    expect(d.bpm, isNull);
    expect(d.scale, ShowScale.normal);
    expect(d.pendingLabel, '5');
  });

  test('number stepper drops the letter and stops at 1', () {
    final d = ShowDraft(pendingLabel: '3b');
    d.stepNumber(1);
    expect(d.pendingLabel, '4');
    d.stepNumber(-1);
    d.stepNumber(-1);
    expect(d.pendingLabel, '2');
    d.stepNumber(-5);
    expect(d.pendingLabel, '1');
  });

  test('letter stepper adds, advances and removes letters', () {
    final d = ShowDraft(pendingLabel: '3');
    d.stepSuffix(1);
    expect(d.pendingLabel, '3a');
    d.stepSuffix(1);
    expect(d.pendingLabel, '3b');
    d.stepSuffix(-1);
    d.stepSuffix(-1);
    expect(d.pendingLabel, '3');
    d.stepSuffix(-1);
    expect(d.pendingLabel, '3');
  });

  test('steppers on free text start from the last numeric label', () {
    final d = ShowDraft(pendingLabel: '5');
    d.setPendingLabel('intro');
    d.stepNumber(1);
    expect(d.pendingLabel, '6');
  });

  test('stepped label becomes the base for auto-advance', () {
    final d = ShowDraft(pendingLabel: '1');
    d.stepSuffix(1);
    d.setBpm(100);
    d.commit();
    expect(d.pendingLabel, '2');
  });
}
