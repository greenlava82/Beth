# SCBeatWiz (SC Beat Wizard)

Flutter app for live musicians: a setlist-driven visual metronome that listens
through the mic and detects the band's tempo in real time. Primary target is
Android (tested on a Pixel); the other Flutter platforms are scaffolded but not
maintained.

## Naming

- **SCBeatWiz** — short name: Android launcher label, iOS `CFBundleName`, web
  `short_name`, macOS bundle, Dart package (`scbeatwiz`), root widget
  (`SCBeatWizApp`), repo.
- **SC Beat Wizard** — full name: app/window titles, iOS display name, web
  title and descriptions.
- Never "BPM Metronome" or `bpm_metronome` in anything user-facing.
- The app IDs are deliberately still `com.example.bpm_metronome` (Android) and
  `com.example.bpmMetronome` (iOS/macOS); changing them makes a new app that
  loses existing installs' saved setlists. Don't change them without asking.

## Layout

- `lib/main.dart` — the whole UI and app state (`MetronomeScreen`): setlists,
  metronome, tempo graph, mic handling, MIDI trigger, persistence.
- `lib/tempo_detector.dart` — `TempoDetector`, pure Dart, no Flutter imports.
  Spectral-flux onset detection (2048 FFT, 10 ms hop, log bands) → harmonic-comb
  autocorrelation over the last 8 s → octave choice via a preferred range +
  optional hint (the song's BPM) → smoothed estimate with confidence 0..1.
- `lib/tempo_lock.dart` — `TempoLock`, decides when the detected tempo has
  locked onto the song's marking (±3%, conf ≥ 0.2, held 3 s) so the count-in
  metronome can auto-pause.
- `test/tempo_detector_test.dart` — synthesizes audio (drums, snaps, piano,
  guitar, legato bass, swing, 3/4, tempo change, noise) and checks detection.
- `test/tempo_lock_test.dart` — unit tests for `TempoLock`.
- `test/widget_test.dart` — app smoke test.

Persisted in `SharedPreferences`: `playlists` (JSON), `preferredMinBpm`,
`preferredMaxBpm`, `historyMinutes`. Changing their shape needs a migration or
a tolerant loader.

## Build, run, test

```bash
flutter pub get
flutter analyze lib test        # must report "No issues found!"
flutter test                     # all tests must pass
flutter test test/tempo_detector_test.dart -r expanded   # prints each detected tempo
```

Run on Android:

```bash
flutter devices
flutter emulators --launch Medium_Phone_API_36.1
flutter run -d <device-id>               # debug, hot reload with r / R
flutter run --release -d <device-id>     # use for judging detection timing
```

Build and sideload without `flutter run`:

```bash
flutter build apk --debug
adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s <device-id> shell am start -n com.example.bpm_metronome/.MainActivity
adb -s <device-id> exec-out screencap -p > shot.png
```

Notes:
- The app needs the microphone. On the emulator, enable *Virtual microphone
  uses host audio input* (Extended Controls → Microphone). MIDI only really
  works on hardware.
- After `am start`, wait until `adb shell dumpsys window | grep mCurrentFocus`
  shows `bpm_metronome` before tapping or screenshotting; early screenshots are
  black. If the phone is locked, ask the user to unlock it — never enter a PIN.
- Adding a plugin regenerates `macos/Flutter/GeneratedPluginRegistrant.swift`;
  commit it with the dependency change.

## Making changes

- Detection logic belongs in `tempo_detector.dart` / `tempo_lock.dart`, not
  `main.dart`, and must come with tests. Keep those files free of Flutter
  imports so they stay fast to unit-test.
- When tuning the detector, run the full synthetic suite: fixes for one case
  (e.g. octave choice) easily regress another (e.g. 3/4 time reading as 2/3
  tempo).
- `main.dart` is **not** `dart format`-clean. Don't run `dart format` on it
  (it rewrites the whole file and buries the real change); match the
  surrounding style by hand. Formatting new standalone files is fine.
- Prefer verifying UI changes on a real device or emulator (screenshot) in
  addition to `flutter analyze`.

## Commits

- **Atomic commits:** one commit per feature or concern. Split logic + tests
  from UI wiring, and separate unrelated UI changes, even when they were built
  together. Every commit must pass `flutter analyze` on its own (and
  `flutter test` when it touches tested code).
- Subject: imperative, ≤ ~65 chars, no trailing period
  (e.g. "Add Capture button to save the heard tempo to the song").
  Body: what changed and why, wrapped prose; mention user-visible behavior and
  any thresholds/defaults chosen.
- Never commit `.vscode/` or `devtools_options.yaml` (local editor files).
- Work on a feature branch; `main` is updated via GitHub PRs.
- Push only when asked. Rewriting pushed history (rebase to split commits)
  needs explicit approval, and then `git push --force-with-lease`.

## Git / GitHub

- Remote: `origin` = `git@github-greenlava82:greenlava82/SCBeatWiz.git`. The
  `github-greenlava82` SSH alias selects the right key; the plain `github.com`
  host authenticates as a different (work) account and gets "permission
  denied". Don't change the remote URL or SSH config.
- `gh` is logged in as greenlava82; use `--repo greenlava82/SCBeatWiz`.
- No CI is configured — local `flutter analyze` + `flutter test` are the gate.
