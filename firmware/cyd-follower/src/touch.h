// The CYD's resistive touch panel (XPT2046 on its own pins), read by
// bit-banged SPI so it doesn't share or reconfigure the display's bus.
#pragma once

#include <stdint.h>

struct TouchPoint {
  int x;  // screen pixels, landscape (320 x 240)
  int y;
  uint16_t rawX;
  uint16_t rawY;
};

// The panel's "pressed" line (low while pressed). An RTC pin, so a tap can
// wake the ESP32 from deep sleep.
constexpr int kTouchIrqPin = 36;

void touchBegin();

// True while the panel is pressed, with the averaged position.
bool touchRead(TouchPoint& p);
