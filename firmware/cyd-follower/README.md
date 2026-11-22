# CYD band sync follower

A small hardware follower for Beth band sync: an ESP32 "Cheap Yellow
Display" (ESP32-2432S028R) that shows what the leader phone hears. Put it on
the drum riser or a mic stand, power it from USB, and it shows the leader's
tempo with no phone, pairing or app.

It shows:

- the leader's session icon (e.g. a green anchor), the playlist name and
  *Song 2 of 12*
  (or *COUNT-IN* while the leader's count-in metronome runs);
- the song name with its target tempo, and the song up next (or *Free
  running*);
- the heard tempo, large, in the leader's drift colour (green on tempo, amber
  drifting, red off), with *▲ 4.0 rushing* / *▼ 2.1 dragging* or *on tempo*;
- the heard tempo fades when the leader's confidence is low;
- an orange banner after 4 s with no news and a red *Lost the leader* banner
  after 12 s, so a frozen number never looks live (the number turns grey);
- the drift colour on the board's RGB LED.

The live numbers come from the leader's advertisement, without connecting.
Like the phone follower, it connects once to read the playlist and song
names (shown as *Getting song names...* meanwhile; the leader's band menu
counts it as joined), and again only when the leader's setlist changes.
Accents and typographic quotes are simplified for the screen's fonts
(*Ça va* shows as *Ca va*); emoji show as `?`.

## Choosing a leader

Like the phone follower, it joins by itself when only one leader is nearby
(it listens for 2 s first, so every nearby leader has a chance to be heard).
With several, it shows **Choose a leader**: one row per leader with its
session icon, name and code (*Green anchor 5F6E*; the code tells apart two
leaders that happen to share an icon), song, target, heard tempo and signal
strength. Tap the icon that matches the leader's phone.

While following, the bottom line says *tap the screen to switch leader*
when another leader is around. Tap anywhere to open the list (the current
leader is marked *FOLLOWING*), then pick another or tap **Back**. The list
closes by itself after 20 s untouched.

If the leader is lost (12 s with no news), it switches by itself when exactly
one other leader is live (for example after the leader stops and starts
leading again, which picks a new code but keeps the band's icon), and asks
when there are several.

The touch panel is resistive: press firmly with a fingernail or stylus.

## Sleep

- **Hold the screen** for 2 s to sleep: after 0.7 s it says *Keep holding
  to sleep* (let go to cancel).
- With **no leader nearby for a minute** (a lost leader counts as gone,
  so about 72 s after the leader stops), it sleeps by itself.
- **Tap the screen** to wake. It starts afresh, finds the leader and reads
  the names again within a few seconds.

Asleep, the ESP32 is in deep sleep with the radio off, the display panel
asleep and the backlight and LED off. It can't hear leaders while asleep,
so a tap is the only way to wake it. The board's USB-serial chip and
regulator still draw a few milliamps (unmeasured). Some USB power banks
switch off at such a low load; then the CYD loses power and needs the
bank's button instead of a tap.

## Build and flash

Needs [PlatformIO](https://platformio.org/) (`brew install platformio`).
Plug the CYD in by USB, then from this folder:

```bash
pio run -t upload
pio device monitor
```

Each build is stamped with the app's version, the git commit count as its
build number and the commit hash (`version.py`, same scheme as the app's
`tool/flutter_versioned.sh`). The start screen shows `1.0.0 build 135` at
the top right, and the serial log starts with
`Beth CYD follower 1.0.0 (build 135, 985ed42)`.

The serial monitor (115200 baud) logs every new state, e.g.
`5F6E # 72 song=1 target=100.0 heard=104.0 conf=0.91 drift=2 … rssi=-57`.

If uploading fails with "serial noise or corruption", lower `upload_speed`
in `platformio.ini`; 460800 works over the USB-C port.

## Display variants

CYD boards vary. The settings in `platformio.ini` are for the board this was
tested on (micro-USB + USB-C), which has an ILI9341 controller:

- **White screen, nothing drawn:** wrong controller. Swap the
  `ILI9341_2_DRIVER` line for `ST7789_DRIVER`.
- **Light background, odd colours:** the panel is inverted; call
  `tft.invertDisplay(true)` after `tft.init()` in `src/display.cpp`.
- **Taps land in the wrong place:** build with `-DTOUCH_DEBUG=1` (for
  example `PLATFORMIO_BUILD_FLAGS=-DTOUCH_DEBUG=1 pio run -t upload`). The
  serial log then prints raw readings while the screen is pressed. Press
  near each edge and set `TOUCH_LEFT` / `TOUCH_RIGHT` / `TOUCH_TOP` /
  `TOUCH_BOTTOM` in `src/touch.cpp` (or as build flags) to the raw values
  at the edges.

The screen is drawn a third at a time into a 16-bit buffer. A whole-screen
8-bit buffer showed wrong colours on this board, so don't switch back to one.

## Code

- `lib/band_sync/` — payload decoder and freshness rules, a C++ port of
  `lib/band_sync_protocol.dart`, plus the session icon mapping
  (`lib/band_sync_icon.dart`), the details JSON parser and the text cleanup
  for the fonts. No Arduino dependencies.
- `src/leaders.*` — leaders heard nearby, by session id (thread-safe; the
  BLE scan runs on its own task).
- `src/display.*` — the screen layouts (follower and leader list) and the
  RGB LED.
- `src/branding_images.h` — **generated** by the app's
  `tool/render_branding_test.dart`: the Beth mark shown on the
  searching screen and, faintly, behind the follower screen.
- `src/session_icons.h` — **generated** by the app's
  `tool/render_session_icons_test.dart`: the 16 session icon shapes as
  4-bit alpha masks (from the Material icons the app shows), tinted with
  the icon's colour when drawn. Regenerate after changing the shapes.
- `src/touch.*` — the XPT2046 touch panel on its own SPI bus, mapped to
  screen pixels.
- `src/main.cpp` — passive NimBLE scan (no duplicate filtering, so every
  repeat is seen), choosing a leader and handling taps, reading the names,
  sleep, redrawing only when something shown changes.
- `test/band_sync_vectors.h` — **generated** from the app's encoder by
  `test/band_sync_vectors_test.dart` in the app; `flutter test` fails if it's
  out of date. Regenerate with
  `UPDATE_VECTORS=1 flutter test test/band_sync_vectors_test.dart`.

Run the decoder tests on your computer (no board needed):

```bash
pio test -e native
```

Byte order matters: BLE sends a 128-bit UUID little-endian, so over the air
the payload's first byte (`0x5C`) comes last.

An Android leader gets a new random Bluetooth address every time it
re-advertises (on every update, up to four times a second), and the old
address stops answering. So the firmware waits for the first advertisement
of a new sequence and connects to that address at once. About half the
reads still miss the first time and succeed on a retry a second later.
