# CYD band sync follower

A small hardware follower for SCBeatWiz band sync: an ESP32 "Cheap Yellow
Display" (ESP32-2432S028R) that shows what the leader phone hears. Put it on
the drum riser or a mic stand, power it from USB, and it shows the leader's
tempo with no phone, pairing or app.

It shows:

- the leader's code (e.g. `5F6E`) and song number;
- the target tempo (or *Free running*) and *COUNT-IN* while the leader's
  count-in metronome runs;
- the heard tempo, large, in the leader's drift colour (green on tempo, amber
  drifting, red off), with *▲ 4.0 rushing* / *▼ 2.1 dragging* or *on tempo*;
- detection confidence as a bar;
- an orange banner after 4 s with no news and a red *Lost the leader* banner
  after 12 s, so a frozen number never looks live (the number turns grey);
- the drift colour on the board's RGB LED.

It only listens: it decodes the leader's advertisement and never connects.
It follows the strongest leader it hears, and switches by itself when that
leader is lost and another is broadcasting (for example after the leader
stops and starts leading again, which picks a new code).

Not yet: song names (the one-off details read over GATT) and touch to choose
between several leaders.

## Build and flash

Needs [PlatformIO](https://platformio.org/) (`brew install platformio`).
Plug the CYD in by USB, then from this folder:

```bash
pio run -t upload
pio device monitor
```

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

The screen is drawn a third at a time into a 16-bit buffer. A whole-screen
8-bit buffer showed wrong colours on this board, so don't switch back to one.

## Code

- `lib/band_sync/` — payload decoder and freshness rules, a C++ port of
  `lib/band_sync_protocol.dart`. No Arduino dependencies.
- `src/leaders.*` — leaders heard nearby, by session id (thread-safe; the
  BLE scan runs on its own task).
- `src/display.*` — the screen layout and the RGB LED.
- `src/main.cpp` — passive NimBLE scan (no duplicate filtering, so every
  repeat is seen), choosing a leader, redrawing only when something shown
  changes.
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
