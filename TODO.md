# SCBeatWiz — TODO and ideas

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
