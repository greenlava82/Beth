# Show creation mode: plan

A third mode beside setlist and free-running, for quickly sketching a show:
capture each song's tempo, give it a number, and name things later. It reuses
free-running's graph-only layout and detector handling, the existing nudge
buttons and `_setSongBpm`.

Status: implemented (all six steps). The scale readout shows the unrounded
scaled heard tempo; Capture saves it rounded.

## Decisions

- **A draft, not a playlist edit.** Entering the mode creates a new playlist
  for the show (default name "New show"). Nothing touches an existing setlist.
- **A song's number is its `name`** ("1", "2a"). No change to `SetlistItem`,
  JSON, export or band sync. No per-song icons.
- **Wide, unrestricted listening.** `expectedBpm = null`, preferred range about
  40–240. `_updateMetronomeTempo()` must not retune the detector while the mode
  is on (same rule as free-running).
- **The metronome** plays the working BPM only when the user presses play.
  `TempoLock` is disarmed.

## Controls

- **Capture**: sets the working BPM from the (scaled) heard tempo. Can be
  pressed any number of times; each press overwrites.
- **Tap**: tap-tempo (average the last 4–6 taps, reset after about 2 s idle).
  Sets the working BPM directly, ignoring the scale.
- **−5, −1, +1, +5**: the existing `_buildNudgeColumn`, on the working BPM.
  Also ignore the scale.
- **½ | 1 | 2 scale selector**: see below.
- **Commit**: appends a `SetlistItem` named with the pending label to the
  show's playlist, with an Undo snackbar. Working BPM and scale then reset.

### Half-time / double-time scale

A display modifier for the song being captured, not a listener setting.

- If the detector hears 140 and the user selects ½, the readout shows 70 and
  Capture saves 70.
- It applies to whatever is heard, so it persists across repeated captures of
  the same song, until changed or committed.
- **Commit resets it to 1**, as does leaving the mode.
- A selector, not a stack: ½ twice does not give ¼. Tapping the active option
  returns to 1; ½ then 2 simply switches.
- A "×½" / "×2" badge sits beside the readout while a scale is active.
- Result clamped to 30–300. The detector itself is untouched.

### Numbering

A pending label is shown next to Commit and is always overridable (tap it to
type any value: "7", "4c", "intro").

- **Next whole**: "3b" → "4".
- **Next sub**: "3" → "3a", "3a" → "3b". Letters run a..z, then aa, ab, …
- **Auto-advance after commit** (Whole/Sub toggle, default Whole): after
  committing "3" the pending label becomes "4" (Whole) or "3a" (Sub).
- A manual edit sets the base for later advances.
- A duplicate label shows a warning but is not blocked.

## Where the logic lives

Pure Dart, no Flutter imports, with tests:

- `lib/show_numbering.dart`: parse a label into number and suffix, next whole,
  next sub, ordering.
- `lib/tap_tempo.dart`: tap averaging and idle timeout.
- `lib/show_draft.dart`: `ShowDraft` holds the working BPM, scale, pending
  label and auto-advance setting; owns `capture(heardBpm)`, `nudge`, `tap`,
  `commit`. Tests cover: scale cleared on commit, scale persists across
  captures of one song, tapping the active option resets to 1, clamping,
  whole/sub auto-advance.

`main.dart` only wires these to the UI. The `_freeRunning` boolean (about 10
call sites) becomes a small mode enum first, as a pure refactor.

## Commit order

Each commit must pass `flutter analyze`, and `flutter test` when it touches
tested code.

1. Add `show_numbering.dart` with tests.
2. Add `tap_tempo.dart` with tests.
3. Add `show_draft.dart` with tests.
4. Replace the `_freeRunning` boolean with a mode enum (no behaviour change).
5. Add the show-builder UI.
6. Update `CLAUDE.md` (new files and the mode).

Verify the UI on the Pixel in both orientations, using a release build for
detector behaviour.
