# Beth — TODO and ideas

Planning notes to come back to. Started 2026-11-16.

## Next up

### 1. Band sync (leader → followers) — prototype built

Built on the `band-sync` branch: one leader broadcasts song, target, heard
BPM, confidence, drift and count-in state over Bluetooth LE advertisements
(packed into a 128-bit service UUID, since iOS can't advertise other data);
followers mirror it without connecting, and connect once to read the playlist
and song names. See README "Band sync" and `lib/band_sync_protocol.dart`.

Tested: Pixel leader → Mac follower (join, song change, drift, stale/lost
banners) and Mac leader → Pixel follower (join, song names). The Mac has the
same advertising limits as an iPhone, so this covers the iOS-leader case.

**Still to test**

- [ ] Real iPhones as leader and follower (only the Mac has been tested).
- [ ] Range and reliability on a real stage, with several followers.
- [ ] A full-length set (battery on leader and followers; the follower scan
      restarts every 10 min).
- [ ] First-run permission flow on a fresh Android install (fixed, not
      re-tested) and on iOS.

**Ideas / open questions**

- [ ] Followers could show a tempo graph built from the broadcast readings.
- [ ] Leader handover if the leader's battery dies (follower becomes leader;
      a new session code today).
- [ ] Followers are display-only for now; should they nudge or advance songs?
- [ ] Leader's app must stay on screen (phones stop broadcasting in the
      background) — worth a reminder on the leader's screen?
- [ ] Option to hide song names (followers then show "Song 3").
- [ ] Synced count-in flash on followers, matching the leader's screen
      (visual only, ±30–50 ms). Advertisement arrival jitters ±50–150 ms, so
      don't send per-beat updates: followers estimate the leader's clock with
      a few NTP-style pings over GATT (keep the shortest round trip, redo
      every minute or so), the payload carries "beat 1 at leader time T"
      (2 bytes, ms mod 65.536 s; needs a protocol version bump), and each
      device flashes locally. On the CYD flash a small region, not the whole
      screen. Measure the ping round trip on Pixel + Mac first. On hold until
      it's clear it's worth it.

### 2. Build-setlist mode (rehearsal)

Build a setlist by playing through songs at rehearsal.

- A **Build setlist** mode (new playlist, or append to the current one).
- **Capture** saves the currently heard BPM as a **new song** at the end of
  the playlist (instead of overwriting the current song's BPM), named
  "Song N" by default and renamable inline or later.
- Optionally record each song's length from when listening starts to the
  next Capture.
- Undo for the last capture.
- Open questions:
  - [ ] Prompt for a name on each capture, or name them all afterwards?
  - [ ] Should it use free-running detection (no target, common-tempo
        weighting) while building? Probably yes.

### 3. Performance log and set report

- Record each song's tempo history per performance (date, song, target,
  readings with confidence).
- After the gig: a set report per song (average, min/max, % of time on tempo,
  where it rushed or dragged).
- Suggest updating a song's target from its last few performances.
- Export (CSV / share).
- Feeds into band sync later (followers could see the leader's report).

### 4. Watch display (Wear OS / Apple Watch)

- Glanceable BPM, drift colour/arrow and next song on the wrist for a drummer
  or singer.
- Phone does the detection; the watch only displays (and maybe has
  Next/Previous).
- Needs native companion apps (Wear OS: Kotlin/Compose or Flutter on Wear;
  Apple Watch: Swift/SwiftUI via WatchConnectivity). Larger effort.

### 5. Standalone CYD (detector, leader, setlists on the ESP32)

Turn the CYD follower (`firmware/cyd-follower`) into a device that can also
listen and lead without a phone. Planned 2026-11-17; an INMP441 I2S mic is
on order (stage 1 steps 1–3 don't need it).

**Decisions**

- One firmware with a **Follow / Lead** choice on the start screen; rename
  the folder to `firmware/cyd` once it leads.
- Setlists come from the app over Bluetooth; editing stays on the phone.
- INMP441 on the free pins: SCK → GPIO22, WS → GPIO27 (CN1), SD → GPIO35
  (P3), plus 3.3 V, GND, L/R → GND. That uses every free pin, so a
  footswitch needs the SD slot's pins (5, 18, 19, 23) later.

**Stage 1 — detection on the CYD** (standalone heard-BPM display)

- [ ] Run the Dart synthetic suite at 16 kHz (the app only uses 44.1 kHz);
      if it regresses, port at 44.1 kHz instead.
- [ ] Port `tempo_detector.dart` to C++ (`lib/tempo/`, no Arduino deps), in
      `float` (the ESP32 FPU is single precision; doubles are emulated),
      esp-dsp FFT on the board, plain FFT on the host.
- [ ] Shared test audio: a Dart test writes the synthesized clips as PCM plus
      the Dart-detected tempo; `pio test -e native` checks the C++ port
      matches. Clips regenerated, not committed; the C++ test skips if missing.
- [ ] I2S mic driver, heard BPM + confidence screen, serial log of CPU time
      per frame (expect ~10% of a core).
- [ ] Live test: phone playing tracks, then a real kit at volume.

**Stage 2 — setlists from the app**

- [ ] Transfer protocol in pure Dart (`lib/device_transfer_protocol.dart`)
      plus C++ port with shared vectors: the backup JSON in numbered chunks
      (a characteristic holds ≤ 512 bytes) with a CRC at the end.
- [ ] CYD: "setlist inbox" service, LittleFS partition (one USB reflash),
      playlist chooser, song screen with target + heard BPM; tap right/left
      half = next/previous song, 2 s hold still sleeps.
- [ ] App: **Send to device** in the backup sheet (scan, pick a CYD, send);
      own commit, separate from the protocol. Test on Pixel and macOS.

**Stage 3 — CYD as leader**

- [ ] Port the encoder (`encodeBandSyncPayload`, `BandSyncDetails.toBytes`)
      to C++, checked against the same vectors in reverse.
- [ ] Re-enable NimBLE broadcaster/peripheral roles; advertise on change +
      1 s heartbeat; serve the details characteristic; no scanning in Lead.
- [ ] Test with the Pixel and the macOS app as followers at once; measure
      load with detector + BLE + display running together.

**Stage 4 — metronome, drift, graph, capture**

- [ ] Port `tempo_drift.dart` and `tempo_lock.dart` with tests (drift
      colours, rushing/dragging badge).
- [ ] Count-in: screen flash, optional click on the speaker amp (GPIO26),
      auto-pause on lock.
- [ ] Tempo graph (heard + target over N minutes, ~2 redraws/s).
- [ ] Capture to flash; **Fetch from device** in the app shows the changes
      before applying them.

**Stage 5 — optional**

- [ ] Footswitch via the SD slot pins.
- [ ] Battery life on a power bank.
- [ ] Backlight dimming from the LDR (GPIO34).

**Risks to check early:** float vs double drift (stage 1 vectors), CPU/RAM
with everything running (stage 3), mic at stage volume (INMP441 ≈ 120 dB SPL
max; placement likely matters more).

## Backlog (other ideas)

- [ ] **Stage mode:** huge high-contrast readout (BPM, drift arrow, next
      song) readable from a drum stool.
- [ ] **Dim display option** for long sets (battery and glare).
- [ ] **Tap tempo** in the song editor.
- [ ] **Set clock:** elapsed vs. planned set length from song durations
      ("4 min over").
- [ ] **Count-in click in headphones** (drummer's in-ears): local and
      sample-accurate, avoids the network timing problem.
- [ ] **Auto-advance hint:** detect the gap between songs and offer
      "Next song?" (suggest only, never automatic).

## Known small issues

- [ ] iOS splash screen: status bar icons are dark on the dark background.
