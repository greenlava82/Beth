#include "touch.h"

#include <Arduino.h>
#include <SPI.h>
#include <XPT2046_Touchscreen.h>

namespace {

// XPT2046 wiring on the CYD: its own pins, so it gets the ESP32's second
// SPI bus (the display uses HSPI).
constexpr int kIrq = 36;
constexpr int kMosi = 32;
constexpr int kMiso = 39;
constexpr int kClk = 25;
constexpr int kCs = 33;

SPIClass touchSpi(VSPI);
XPT2046_Touchscreen panel(kCs, kIrq);

// Calibration for landscape: the raw readings at the screen's edges. On the
// tested board the centre reads about (2150, 2145) and points near the
// corners about 250 and 3700. Overridable from platformio.ini.
#ifndef TOUCH_LEFT
#define TOUCH_LEFT 300
#endif
#ifndef TOUCH_RIGHT
#define TOUCH_RIGHT 4000
#endif
#ifndef TOUCH_TOP
#define TOUCH_TOP 350
#endif
#ifndef TOUCH_BOTTOM
#define TOUCH_BOTTOM 3940
#endif

int mapClamped(int v, int from0, int from1, int to1) {
  const long r = static_cast<long>(v - from0) * to1 / (from1 - from0);
  return constrain(static_cast<int>(r), 0, to1 - 1);
}

}  // namespace

void touchBegin() {
  touchSpi.begin(kClk, kMiso, kMosi, kCs);
  panel.begin(touchSpi);
  panel.setRotation(1);  // landscape, like the display
}

bool touchRead(TouchPoint& p) {
  if (!panel.touched()) return false;
  const TS_Point raw = panel.getPoint();
  p.rawX = raw.x;
  p.rawY = raw.y;
  p.x = mapClamped(raw.x, TOUCH_LEFT, TOUCH_RIGHT, 320);
  p.y = mapClamped(raw.y, TOUCH_TOP, TOUCH_BOTTOM, 240);
  return true;
}
