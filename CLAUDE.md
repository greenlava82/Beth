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
- `lib/playlist.dart` — `Playlist` / `SetlistItem` (name, BPM, time
  signature, notes, optional duration), JSON encode/decode (tolerant of old
  or partial data), duration helpers. Pure Dart.
- `lib/playlist_text.dart` — plain-text setlist export (`playlistToText`) and
  lenient import (`parsePlaylistText`, also accepts the app's JSON). Pure Dart.
- `lib/tempo_detector.dart` — `TempoDetector`, pure Dart, no Flutter imports.
  Spectral-flux onset detection (2048 FFT, 10 ms hop, log bands) → harmonic-comb
  autocorrelation over the last 8 s → octave choice via a preferred range +
  optional hint (the song's BPM) → smoothed estimate with confidence 0..1.
- `lib/tempo_lock.dart` — `TempoLock`, decides when the detected tempo has
  locked onto the song's marking (±3%, conf ≥ 0.2, held 3 s) so the count-in
  metronome can auto-pause.
- `test/tempo_detector_test.dart` — synthesizes audio (drums, snaps, piano,
  guitar, legato bass, swing, 3/4, tempo change, noise) and checks detection.
- `lib/tempo_drift.dart` — `TempoDriftTracker`: on tempo (±2%) / drifting
  (2–5%) / off (>5%) vs the song's BPM, with 1% hysteresis and half/double-time
  handling; drives the readout colour and rushing/dragging badge. Pure Dart.
- `test/tempo_lock_test.dart` — unit tests for `TempoLock`.
- `test/tempo_drift_test.dart` — unit tests for `TempoDriftTracker`.
- `test/playlist_test.dart`, `test/playlist_text_test.dart` — model, JSON
  compatibility, durations, and share/import format tests.
- `test/widget_test.dart` — app smoke test.

Persisted in `SharedPreferences`: `playlists` (JSON), `preferredMinBpm`,
`preferredMaxBpm`, `historyMinutes`, `currentPlaylist`, `currentSong`.
Changing their shape needs a migration or a tolerant loader; new song fields
must default sensibly in `SetlistItem.fromJson` (see `playlist_test.dart`).

All song changes go through `_goToSong()` (starts the count-in metronome on
beat 1, resets the detector, arms `TempoLock`, leaves free-running mode);
playlist list changes go through `_changePlaylists()` (keeps the current
playlist selected). `_setFreeRunning()` toggles free-running mode (no target:
detector hint 120 BPM, preferred range 80–160, graph-only layout);
`_updateMetronomeTempo()` must not retune the detector while it's on.

The main screen is built from `_buildGraphSection()` and
`_buildControlsSection()` (portrait: stacked; landscape: side by side;
free-running: graph only). Check UI changes in both orientations.

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

## Branding (icon and splash)

- Source of truth is `tool/render_branding_test.dart`, which draws the mark
  with Flutter's canvas into `assets/branding/*.png` (no image tools needed).
  Colours: background `#1E1846`, lavender `#CFBCFF`, amber `#FFD180`.
- Regenerate in order:
  `flutter test tool/render_branding_test.dart`, then
  `dart run flutter_launcher_icons`, then `dart run flutter_native_splash:create`.
- After regenerating, review the diff before committing:
  - `flutter_launcher_icons` sets
    `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon` in
    `ios/Runner.xcodeproj/project.pbxproj` (a known bug) — revert it.
  - `flutter_native_splash` reformats `ios/Runner/Info.plist`; keep the
    original formatting and only its `UIStatusBarHidden` key.
  - The Android adaptive foreground gets an extra 16% inset from the
    generator; the render script draws it larger to compensate.
- To see the Android 12+ splash icon when launching from adb, use
  `adb shell am start --splashscreen-show-icon -n …` (shell launches
  otherwise show a plain background).

## Making changes

- Detection logic belongs in `tempo_detector.dart` / `tempo_lock.dart` /
  `tempo_drift.dart`, and
  playlist data/format logic in `playlist.dart` / `playlist_text.dart` — not
  `main.dart` — and must come with tests. Keep those files free of Flutter
  imports so they stay fast to unit-test.
- When tuning the detector, run the full synthetic suite: fixes for one case
  (e.g. octave choice) easily regress another (e.g. 3/4 time reading as 2/3
  tempo).
- `main.dart` is **not** `dart format`-clean. Don't run `dart format` on it
  (it rewrites the whole file and buries the real change); match the
  surrounding style by hand. Formatting new standalone files is fine.
- Prefer verifying UI changes on a real device or emulator (screenshot) in
  addition to `flutter analyze`.
- Battery: the app keeps the screen on for hours, so avoid redrawing when
  nothing changes. Keep fl_chart's implicit animation off (`duration:
  Duration.zero`); a tween per update made the whole screen redraw ~30 times
  a second. Listening pauses in the background via
  `didChangeAppLifecycleState`. To measure, use a release build and
  `adb shell top -H -p <pid>` (the `N.raster` thread is drawing) plus
  `dumpsys SurfaceFlinger --latency '<app SurfaceView layer>'` for frames/s.

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
