# SCBeatWiz — TODO and ideas

Planning notes to come back to. Started 2026-11-16.

## Next up

### 1. Band sync (leader → followers)

Everyone in the band sees the same song, target and detected tempo.

**Direction so far**

- **Share numbers, not the pulse.** Song, target BPM, detected BPM, confidence
  and drift change at most a couple of times a second, so network delay
  (5–100 ms+ on Wi-Fi/Bluetooth) doesn't matter. A shared visual metronome
  would need tight clock sync and could mislead if it's even slightly late, so
  it's out of scope.
- **One leader** listens (best-placed mic) and controls the setlist.
  **Followers** mirror the screen: current song, up next, target, detected
  BPM, drift colour, graph. Followers don't run their own detection (each
  phone hears a different mix).
- **The setlist follows the leader:** Next / Previous / jump / MIDI foot
  switch on the leader moves everyone. Probably the biggest practical win.
- **The leader pushes the setlist** to followers when they join (reuse the
  share/JSON format in `lib/playlist_text.dart`).
- **Followers must show staleness** ("last update 5 s ago" / disconnected) so
  a frozen reading never looks live.

**Transport options** (preferred first)

1. Local Wi-Fi or the leader's phone hotspot: the leader runs a small server,
   followers join via QR code or room code. Works offline and on iOS and
   Android.
2. Bluetooth LE broadcast: no network needed, but iOS restricts advertising
   (especially in the background), awkward for mixed iPhone/Android bands.
3. Cloud (e.g. Firebase): simplest to build, but needs internet at the venue
   and accounts.
4. Ableton Link: the standard for music apps, but GPL/commercial licence
   doesn't fit this MIT project, and it's built for beat-phase sync.

**Open questions**

- [ ] Is the band a mix of iPhones and Androids?
- [ ] Is Wi-Fi reliable at venues, or would one phone act as a hotspot?
- [ ] Can a follower take over as leader (e.g. leader's battery dies)?
- [ ] Are followers display-only, or can they nudge/capture too?

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
