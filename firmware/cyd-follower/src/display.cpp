#include "display.h"

#include <Arduino.h>
#include <TFT_eSPI.h>
#include <driver/gpio.h>

#include "branding_images.h"
#include "session_icons.h"
#include <ctype.h>
#include <string.h>

using bandsync::Drift;
using bandsync::Link;

namespace {

TFT_eSPI tft;

constexpr int kW = 320;
constexpr int kH = 240;

// The screen is drawn off-screen a third at a time into one 16-bit strip
// (51 KB) and pushed, so updates never flicker. (A whole-screen 8-bit
// sprite would fit too, but its colours came out wrong on the CYD.)
constexpr int kStripH = 80;
TFT_eSprite strip(&tft);
bool haveStrip = false;

// The app's colours (Material accents), as RGB565. Green is purer than the
// app's mint (#69F0AE), which looks pale blue on the CYD's panel.
constexpr uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}
constexpr uint16_t kGreen = rgb(0x30, 0xF0, 0x30);
constexpr uint16_t kAmber = rgb(0xFF, 0xC1, 0x07);
constexpr uint16_t kRed = rgb(0xFF, 0x52, 0x52);
constexpr uint16_t kTeal = rgb(0x64, 0xFF, 0xDA);
// White for the BPM readout, a little dimmed: pure white is glaring.
constexpr uint16_t kSoftWhite = rgb(0xC8, 0xC8, 0xC8);
constexpr uint16_t kGrey = rgb(0x9E, 0x9E, 0x9E);
constexpr uint16_t kDim = rgb(0x30, 0x30, 0x38);
constexpr uint16_t kBg = rgb(0x12, 0x10, 0x18);
constexpr uint16_t kBannerAmber = rgb(0xFF, 0x6F, 0x00);
constexpr uint16_t kBannerRed = rgb(0xB7, 0x1C, 0x1C);
static_assert(kBg == kBrandingBackground,
              "regenerate branding_images.h for the new background");

// RGB LED on the back, active low.
constexpr int kLedR = 4;
constexpr int kLedG = 16;
constexpr int kLedB = 17;
constexpr int kLedLevel = 40;  // of 255: it's bright

void setLed(uint8_t r, uint8_t g, uint8_t b) {
  analogWrite(kLedR, 255 - r);
  analogWrite(kLedG, 255 - g);
  analogWrite(kLedB, 255 - b);
}

uint16_t driftColor(Drift d) {
  switch (d) {
    case Drift::OnTempo:
      return kGreen;
    case Drift::Drifting:
      return kAmber;
    case Drift::Off:
      return kRed;
    default:
      return kSoftWhite;
  }
}

// Every draw function takes the canvas and the y offset of the strip being
// rendered (0, -80, -160); anything outside the strip is clipped.

// Draws a run-length encoded image (see branding_images.h) with its top
// left at x, y. Background runs are skipped: the strip is already filled.
void drawRle(TFT_eSPI& c, const uint16_t* runs, int length, int size, int x,
             int y) {
  int px = 0;
  int py = 0;
  for (int i = 0; i + 1 < length; i += 2) {
    const int count = runs[i];
    const uint16_t colour = runs[i + 1];
    if (colour != kBg) c.drawFastHLine(x + px, y + py, count, colour);
    px += count;
    if (px >= size) {
      px = 0;
      py++;
    }
  }
}

constexpr uint16_t rgb888(uint32_t c) {
  return rgb(c >> 16, (c >> 8) & 0xFF, c & 0xFF);
}

// The leader's session icon, as in the app: its shape in its colour on a
// dark disc of diameter d centred at cx, cy. The mask comes from
// session_icons.h (4-bit alpha), blended onto the disc.
void drawSessionIcon(TFT_eSPI& c, uint16_t sessionId, int cx, int cy, int d,
                     bool large) {
  const bandsync::Icon icon = bandsync::sessionIcon(sessionId);
  const uint16_t fg = rgb888(bandsync::iconColourRgb(icon.colour));
  c.fillCircle(cx, cy, d / 2, kBg);
  const int size = large ? kSessionIconLargeSize : kSessionIconSmallSize;
  const uint8_t* mask = large ? kSessionIconLarge[icon.shape]
                              : kSessionIconSmall[icon.shape];
  const int rowBytes = (size + 1) / 2;
  const int x0 = cx - size / 2;
  const int y0 = cy - size / 2;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      const uint8_t b = mask[y * rowBytes + x / 2];
      const uint8_t a = x % 2 == 0 ? b >> 4 : b & 0x0F;
      if (a == 0) continue;
      c.drawPixel(x0 + x, y0 + y,
                  a == 15 ? fg : c.alphaBlend(a * 17, fg, kBg));
    }
  }
}

void drawSearching(TFT_eSPI& c, int oy) {
  drawRle(c, kLogo, kLogoLength, kLogoSize, (kW - kLogoSize) / 2, 14 + oy);
  // Version and build (version.py), top right, clear of the logo.
  char version[32];
  snprintf(version, sizeof(version), "%s build %d", BETH_VERSION, BETH_BUILD);
  c.setTextDatum(TR_DATUM);
  c.setTextColor(kGrey, kBg);
  c.drawString(version, kW - 4, 4 + oy, 1);
  c.setTextDatum(MC_DATUM);
  c.setTextColor(kSoftWhite, kBg);
  c.drawString("Looking for a leader...", kW / 2, 130 + oy, 4);
  c.setTextColor(kGrey, kBg);
  c.drawString("On the leader's phone, tap the band", kW / 2, 160 + oy, 2);
  c.drawString("icon and choose \"Lead the band\".", kW / 2, 178 + oy, 2);
  c.drawString("Sleeps after a minute without a leader;", kW / 2, 210 + oy, 1);
  c.drawString("hold the screen to sleep now.", kW / 2, 224 + oy, 1);
}

void drawMessage(TFT_eSPI& c, const char* title, const char* detail,
                 int oy) {
  c.setTextDatum(MC_DATUM);
  c.setTextColor(kSoftWhite, kBg);
  c.drawString(title, kW / 2, 100 + oy, 4);
  c.setTextColor(kGrey, kBg);
  c.drawString(detail, kW / 2, 140 + oy, 2);
}

void drawBanner(TFT_eSPI& c, const View& v, int oy) {
  char text[48];
  uint16_t bg;
  if (v.link == Link::Lost) {
    snprintf(text, sizeof text, "Lost the leader (%lu s) - searching",
             static_cast<unsigned long>(v.ageSec));
    bg = kBannerRed;
  } else {
    snprintf(text, sizeof text, "No update from the leader for %lu s",
             static_cast<unsigned long>(v.ageSec));
    bg = kBannerAmber;
  }
  c.fillRect(0, oy, kW, 24, bg);
  c.setTextDatum(MC_DATUM);
  c.setTextColor(kSoftWhite, bg);
  c.drawString(text, kW / 2, 12 + oy, 2);
}

// Cuts text to fit maxW pixels in font, ending in "..." when cut.
void fitText(TFT_eSPI& c, const char* text, int font, int maxW, char* out,
             size_t n) {
  strlcpy(out, text, n);
  if (c.textWidth(out, font) <= maxW) return;
  size_t len = strlen(out);
  while (len > 0) {
    out[--len] = '\0';
    while (len > 0 && out[len - 1] == ' ') out[--len] = '\0';
    char trial[96];
    snprintf(trial, sizeof trial, "%s...", out);
    if (c.textWidth(trial, font) <= maxW) {
      strlcpy(out, trial, n);
      return;
    }
  }
}

void drawHeader(TFT_eSPI& c, const View& v, int oy) {
  const auto& s = v.state;

  // Right: the count-in while it runs, else the song number.
  char right[24] = "";
  uint16_t rightColor = kGrey;
  if (s.playing) {
    strlcpy(right, "COUNT-IN", sizeof right);
    rightColor = kTeal;
  } else if (!s.freeRunning && s.songIndex >= 0) {
    if (v.songCount > 0) {
      snprintf(right, sizeof right, "Song %d of %d", s.songIndex + 1,
               v.songCount);
    } else {
      snprintf(right, sizeof right, "Song %d", s.songIndex + 1);
    }
  }
  c.setTextDatum(MR_DATUM);
  c.setTextColor(rightColor);
  c.drawString(right, kW - 8, 12 + oy, 2);
  const int rightW = right[0] ? c.textWidth(right, 2) + 12 : 0;

  // Left: the leader's icon, other leaders, and the playlist. (The code is
  // only in the picker, to tell apart two leaders sharing an icon.)
  drawSessionIcon(c, s.sessionId, 19, 12 + oy, 22, false);
  char left[96];
  int n = 0;
  left[0] = '\0';
  if (v.otherLeaders > 0) {
    n = snprintf(left, sizeof left, "(+%d)", v.otherLeaders);
  }
  if (v.playlist[0]) {
    snprintf(left + n, sizeof left - n, "%s%s", n ? " " : "", v.playlist);
  }
  char fitted[96];
  fitText(c, left, 2, kW - 44 - rightW, fitted, sizeof fitted);
  c.setTextColor(kGrey);
  c.setTextDatum(ML_DATUM);
  c.drawString(fitted, 36, 12 + oy, 2);
}

void drawMirror(TFT_eSPI& c, const View& v, int oy) {
  const auto& s = v.state;
  const bool live = v.link == Link::Live;

  // The mark, faint, behind everything; text is drawn without background
  // boxes so it shows through.
  drawRle(c, kLogoFaint, kLogoFaintLength, kLogoFaintSize,
          (kW - kLogoFaintSize) / 2, (kH - kLogoFaintSize) / 2 + oy);

  if (live) {
    drawHeader(c, v, oy);
  } else {
    drawBanner(c, v, oy);
  }

  // Song line: the name on the left, the song's target on the right.
  char buf[96];
  int targetW = 0;
  if (!s.freeRunning) {
    if (s.hasTarget()) {
      snprintf(buf, sizeof buf, "%u", (s.target10 + 5) / 10);
    } else {
      strlcpy(buf, "--", sizeof buf);
    }
    c.setTextDatum(MR_DATUM);
    c.setTextColor(kSoftWhite);
    c.drawString(buf, kW - 8, 42 + oy, 4);
    c.setTextColor(kGrey);
    c.setTextDatum(TR_DATUM);
    c.drawString("target", kW - 8, 57 + oy, 1);
    targetW = max(c.textWidth(buf, 4), c.textWidth("target", 1)) + 14;
  }
  const char* songText;
  if (s.freeRunning) {
    songText = "Free running";
  } else if (v.song[0]) {
    songText = v.song;
  } else if (v.readingDetails) {
    songText = "Getting song names...";
  } else if (s.songIndex >= 0) {
    snprintf(buf, sizeof buf, "Song %d", s.songIndex + 1);
    songText = buf;
  } else {
    songText = "No song";
  }
  char fitted[96];
  const bool smallNote = !s.freeRunning && !v.song[0] && v.readingDetails;
  const int songFont = smallNote ? 2 : 4;
  fitText(c, songText, songFont, kW - 16 - targetW, fitted, sizeof fitted);
  c.setTextDatum(ML_DATUM);
  c.setTextColor(smallNote ? kGrey : kSoftWhite);
  c.drawString(fitted, 8, 42 + oy, songFont);

  // Up next, small, under the song name.
  if (!s.freeRunning && v.next[0]) {
    char next[96];
    snprintf(next, sizeof next, "Next: %s", v.next);
    fitText(c, next, 2, kW - 16 - targetW, fitted, sizeof fitted);
    c.setTextColor(kGrey);
    c.drawString(fitted, 8, 66 + oy, 2);
  }

  // The heard tempo, big, in the leader's drift colour.
  const uint16_t color = live ? driftColor(s.drift) : kGrey;
  c.setTextDatum(MC_DATUM);
  c.setTextColor(color);
  if (s.hasHeard()) {
    snprintf(buf, sizeof buf, "%u.%u", s.heard10 / 10, s.heard10 % 10);
    c.drawString(buf, kW / 2, 118 + oy, 8);
  } else {
    c.drawString("--", kW / 2, 118 + oy, 8);
  }
  c.setTextColor(kGrey);
  c.drawString(s.hasHeard() ? "BPM heard" : "leader is listening...", kW / 2,
               166 + oy, 2);

  // Rushing / dragging, as on the app's follower screen.
  if (live && s.drift != Drift::None && s.hasHeard() && s.hasTarget() &&
      !s.freeRunning) {
    c.setTextColor(color);
    if (s.drift == Drift::OnTempo) {
      c.drawString("on tempo", kW / 2, 190 + oy, 4);
    } else {
      const int diff = abs(static_cast<int>(s.heard10) - s.target10);
      snprintf(buf, sizeof buf, "%d.%d %s", diff / 10, diff % 10,
               s.rushing ? "rushing" : "dragging");
      const int w = c.textWidth(buf, 4);
      const int x = kW / 2 - w / 2 - 6;
      if (s.rushing) {
        c.fillTriangle(x - 8, 198 + oy, x + 8, 198 + oy, x, 182 + oy, color);
      } else {
        c.fillTriangle(x - 8, 182 + oy, x + 8, 182 + oy, x, 198 + oy, color);
      }
      c.drawString(buf, kW / 2 + 10, 190 + oy, 4);
    }
  }

  // Confidence bar.
  const int barW = 160;
  const int barX = (kW - barW) / 2;
  const uint16_t barColor = !live                 ? kGrey
                            : s.confidence >= 128 ? kGreen
                            : s.confidence >= 51  ? kAmber
                                                  : kRed;
  c.fillRect(barX, 216 + oy, barW, 5, kDim);
  c.fillRect(barX, 216 + oy, barW * s.confidence / 255, 5, barColor);
  c.setTextColor(kGrey);
  c.drawString(v.otherLeaders > 0
                   ? "confidence  -  tap the screen to switch leader"
                   : "confidence",
               kW / 2, 232 + oy, 1);
}

void drawAll(TFT_eSPI& c, const View& v, int oy) {
  if (!v.hasLeader) {
    drawSearching(c, oy);
  } else {
    drawMirror(c, v, oy);
  }
}

void updateLed(const View& v) {
  if (!v.hasLeader || v.link != Link::Live) {
    setLed(0, 0, 0);
    return;
  }
  switch (v.state.drift) {
    case Drift::OnTempo:
      setLed(0, kLedLevel, 0);
      break;
    case Drift::Drifting:
      setLed(kLedLevel, kLedLevel / 2, 0);
      break;
    case Drift::Off:
      setLed(kLedLevel, 0, 0);
      break;
    default:
      setLed(0, 0, 0);
  }
}

// Picker layout.
constexpr int kTitleH = 36;
constexpr int kRowsTop = 58;
constexpr int kRowH = 45;
constexpr int kBackX = 236;  // the Back button spans to the right edge
constexpr uint16_t kRow = rgb(0x24, 0x22, 0x2E);
constexpr uint16_t kRowFollowed = rgb(0x2E, 0x3A, 0x40);

void drawBars(TFT_eSPI& c, int x, int y, uint8_t bars, uint16_t color) {
  for (int i = 0; i < 3; i++) {
    const int h = 6 + i * 5;
    c.fillRect(x + i * 7, y - h, 5, h, i < bars ? color : kDim);
  }
}

void drawPicker(TFT_eSPI& c, const PickerView& p, int oy) {
  c.setTextDatum(ML_DATUM);
  c.setTextColor(kSoftWhite, kBg);
  c.drawString("Choose a leader", 8, kTitleH / 2 + oy, 4);
  if (p.canGoBack) {
    c.fillRoundRect(kBackX + 8, 4 + oy, kW - kBackX - 14, kTitleH - 8, 6,
                    kRow);
    c.setTextDatum(MC_DATUM);
    c.setTextColor(kSoftWhite, kRow);
    c.drawString("Back", (kBackX + kW) / 2, kTitleH / 2 + oy, 2);
  }
  c.setTextDatum(ML_DATUM);
  c.setTextColor(kGrey, kBg);
  c.drawString("Tap the icon shown on the leader's phone", 8, 46 + oy, 2);

  constexpr int kTextX = 58;
  constexpr int kTextRight = kW - 46;  // clear of the signal bars
  char line[64];
  char heard[24];
  char fitted[64];
  for (int i = 0; i < p.count; i++) {
    const PickerEntry& e = p.rows[i];
    const int top = kRowsTop + i * kRowH + oy;
    const uint16_t bg = e.followed ? kRowFollowed : kRow;
    c.fillRoundRect(6, top + 2, kW - 12, kRowH - 4, 6, bg);
    const int mid = top + kRowH / 2;

    drawSessionIcon(c, e.sessionId, 30, mid, 38, true);

    // Line 1: "Orange anchor 0551", and FOLLOWING on the right.
    int followW = 0;
    if (e.followed) {
      c.setTextDatum(MR_DATUM);
      c.setTextColor(kTeal, bg);
      c.drawString("FOLLOWING", kTextRight, mid - 8, 1);
      followW = c.textWidth("FOLLOWING", 1) + 8;
    }
    bandsync::iconName(bandsync::sessionIcon(e.sessionId), line, sizeof line);
    line[0] = toupper(line[0]);
    fitText(c, line, 2, kTextRight - kTextX - followW - 40, fitted,
            sizeof fitted);
    c.setTextDatum(ML_DATUM);
    c.setTextColor(e.live ? kSoftWhite : kGrey, bg);
    c.drawString(fitted, kTextX, mid - 8, 2);
    char code[5];
    bandsync::sessionCode(e.sessionId, code);
    c.setTextColor(kGrey, bg);
    c.drawString(code, kTextX + c.textWidth(fitted, 2) + 6, mid - 8, 2);

    // Line 2: song and target, then the heard tempo in its drift colour.
    if (e.freeRunning) {
      strlcpy(line, "Free running", sizeof line);
    } else {
      int n = e.songIndex >= 0
                  ? snprintf(line, sizeof line, "Song %d", e.songIndex + 1)
                  : snprintf(line, sizeof line, "No song");
      if (e.target10) {
        snprintf(line + n, sizeof line - n, " - target %u",
                 (e.target10 + 5) / 10);
      }
    }
    if (e.heard10) {
      snprintf(heard, sizeof heard, "heard %u.%u", e.heard10 / 10,
               e.heard10 % 10);
    } else {
      strlcpy(heard, "listening...", sizeof heard);
    }
    const int heardW = c.textWidth(heard, 2);
    fitText(c, line, 2, kTextRight - kTextX - heardW - 8, fitted,
            sizeof fitted);
    c.setTextColor(kGrey, bg);
    c.drawString(fitted, kTextX, mid + 9, 2);
    c.setTextColor(e.live && e.heard10 ? driftColor(e.drift) : kGrey, bg);
    c.drawString(heard, kTextX + c.textWidth(fitted, 2) + 8, mid + 9, 2);
    drawBars(c, kW - 36, mid + 8, e.bars, e.live ? kGreen : kGrey);
  }
}

}  // namespace

bool PickerView::operator==(const PickerView& o) const {
  if (count != o.count || canGoBack != o.canGoBack) return false;
  for (int i = 0; i < count; i++) {
    const PickerEntry& a = rows[i];
    const PickerEntry& b = o.rows[i];
    if (a.sessionId != b.sessionId || a.followed != b.followed ||
        a.live != b.live || a.freeRunning != b.freeRunning ||
        a.songIndex != b.songIndex || a.target10 != b.target10 ||
        a.heard10 != b.heard10 || a.drift != b.drift || a.bars != b.bars) {
      return false;
    }
  }
  return true;
}

int pickerHit(const PickerView& p, int x, int y) {
  if (p.canGoBack && y < kTitleH + 8 && x >= kBackX) return kPickerBack;
  if (y < kRowsTop) return kPickerNothing;
  const int row = (y - kRowsTop) / kRowH;
  return row < p.count ? row : kPickerNothing;
}

void displayDrawPicker(const PickerView& p) {
  if (haveStrip) {
    for (int top = 0; top < kH; top += kStripH) {
      strip.fillSprite(kBg);
      drawPicker(strip, p, -top);
      strip.pushSprite(0, top);
    }
  } else {
    tft.fillScreen(kBg);
    drawPicker(tft, p, 0);
  }
  setLed(0, 0, 0);
}

bool View::operator==(const View& o) const {
  // Everything drawn; the sequence isn't, so heartbeats don't redraw.
  const auto& a = state;
  const auto& b = o.state;
  return hasLeader == o.hasLeader && link == o.link && ageSec == o.ageSec &&
         otherLeaders == o.otherLeaders && a.sessionId == b.sessionId &&
         a.playing == b.playing && a.freeRunning == b.freeRunning &&
         a.rushing == b.rushing && a.drift == b.drift &&
         a.songIndex == b.songIndex && a.target10 == b.target10 &&
         a.heard10 == b.heard10 && a.confidence == b.confidence &&
         songCount == o.songCount && readingDetails == o.readingDetails &&
         strcmp(playlist, o.playlist) == 0 && strcmp(song, o.song) == 0 &&
         strcmp(next, o.next) == 0;
}

void displayDrawMessage(const char* title, const char* detail) {
  if (haveStrip) {
    for (int top = 0; top < kH; top += kStripH) {
      strip.fillSprite(kBg);
      drawMessage(strip, title, detail, -top);
      strip.pushSprite(0, top);
    }
  } else {
    tft.fillScreen(kBg);
    drawMessage(tft, title, detail, 0);
  }
  setLed(0, 0, 0);
}

void displayOff() {
  tft.writecommand(0x28);  // display off
  tft.writecommand(0x10);  // sleep in
  delay(5);
  const int pins[] = {TFT_BL, kLedR, kLedG, kLedB};
  const int levels[] = {LOW, HIGH, HIGH, HIGH};  // the LED is active low
  for (int i = 0; i < 4; i++) {
    pinMode(pins[i], OUTPUT);  // also detaches the LED's PWM
    digitalWrite(pins[i], levels[i]);
    gpio_hold_en(static_cast<gpio_num_t>(pins[i]));
  }
  gpio_deep_sleep_hold_en();
}

void displayBegin() {
  // Undo displayOff()'s pin holds after waking from deep sleep.
  gpio_deep_sleep_hold_dis();
  for (int pin : {TFT_BL, kLedR, kLedG, kLedB}) {
    gpio_hold_dis(static_cast<gpio_num_t>(pin));
  }
  pinMode(kLedR, OUTPUT);
  pinMode(kLedG, OUTPUT);
  pinMode(kLedB, OUTPUT);
  setLed(0, 0, 0);

  tft.init();
  tft.setRotation(1);  // landscape, USB ports on the left
  tft.fillScreen(kBg);

  strip.setColorDepth(16);
  haveStrip = strip.createSprite(kW, kStripH) != nullptr;
  Serial.printf("display: %s\n",
                haveStrip ? "16-bit strip buffer" : "direct (no memory)");
}

void displayDraw(const View& v) {
  if (haveStrip) {
    for (int top = 0; top < kH; top += kStripH) {
      strip.fillSprite(kBg);
      drawAll(strip, v, -top);
      strip.pushSprite(0, top);
    }
  } else {
    tft.fillScreen(kBg);
    drawAll(tft, v, 0);
  }
  updateLed(v);
}
