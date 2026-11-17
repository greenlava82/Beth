#include "display.h"

#include <Arduino.h>
#include <TFT_eSPI.h>
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
constexpr uint16_t kGrey = rgb(0x9E, 0x9E, 0x9E);
constexpr uint16_t kDim = rgb(0x30, 0x30, 0x38);
constexpr uint16_t kBg = rgb(0x12, 0x10, 0x18);
constexpr uint16_t kBannerAmber = rgb(0xFF, 0x6F, 0x00);
constexpr uint16_t kBannerRed = rgb(0xB7, 0x1C, 0x1C);

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
      return TFT_WHITE;
  }
}

// Every draw function takes the canvas and the y offset of the strip being
// rendered (0, -80, -160); anything outside the strip is clipped.

void drawSearching(TFT_eSPI& c, int oy) {
  c.setTextDatum(MC_DATUM);
  c.setTextColor(TFT_WHITE, kBg);
  c.drawString("Looking for a leader...", kW / 2, 90 + oy, 4);
  c.setTextColor(kGrey, kBg);
  c.drawString("On the leader's phone, tap the band", kW / 2, 140 + oy, 2);
  c.drawString("icon and choose \"Lead the band\".", kW / 2, 160 + oy, 2);
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
  c.setTextColor(TFT_WHITE, bg);
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
  c.setTextColor(rightColor, kBg);
  c.drawString(right, kW - 8, 12 + oy, 2);
  const int rightW = right[0] ? c.textWidth(right, 2) + 12 : 0;

  // Left: the leader's code, other leaders, and the playlist.
  char code[5];
  bandsync::sessionCode(s.sessionId, code);
  char left[96];
  int n = snprintf(left, sizeof left, "%s", code);
  if (v.otherLeaders > 0) {
    n += snprintf(left + n, sizeof left - n, " (+%d)", v.otherLeaders);
  }
  if (v.playlist[0]) snprintf(left + n, sizeof left - n, " - %s", v.playlist);
  char fitted[96];
  fitText(c, left, 2, kW - 16 - rightW, fitted, sizeof fitted);
  c.setTextColor(kGrey, kBg);
  c.setTextDatum(ML_DATUM);
  c.drawString(fitted, 8, 12 + oy, 2);
}

void drawMirror(TFT_eSPI& c, const View& v, int oy) {
  const auto& s = v.state;
  const bool live = v.link == Link::Live;

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
    c.setTextColor(TFT_WHITE, kBg);
    c.drawString(buf, kW - 8, 42 + oy, 4);
    c.setTextColor(kGrey, kBg);
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
  c.setTextColor(smallNote ? kGrey : TFT_WHITE, kBg);
  c.drawString(fitted, 8, 42 + oy, songFont);

  // Up next, small, under the song name.
  if (!s.freeRunning && v.next[0]) {
    char next[96];
    snprintf(next, sizeof next, "Next: %s", v.next);
    fitText(c, next, 2, kW - 16 - targetW, fitted, sizeof fitted);
    c.setTextColor(kGrey, kBg);
    c.drawString(fitted, 8, 66 + oy, 2);
  }

  // The heard tempo, big, in the leader's drift colour.
  const uint16_t color = live ? driftColor(s.drift) : kGrey;
  c.setTextDatum(MC_DATUM);
  c.setTextColor(color, kBg);
  if (s.hasHeard()) {
    snprintf(buf, sizeof buf, "%u.%u", s.heard10 / 10, s.heard10 % 10);
    c.drawString(buf, kW / 2, 118 + oy, 8);
  } else {
    c.drawString("--", kW / 2, 118 + oy, 8);
  }
  c.setTextColor(kGrey, kBg);
  c.drawString(s.hasHeard() ? "BPM heard" : "leader is listening...", kW / 2,
               166 + oy, 2);

  // Rushing / dragging, as on the app's follower screen.
  if (live && s.drift != Drift::None && s.hasHeard() && s.hasTarget() &&
      !s.freeRunning) {
    c.setTextColor(color, kBg);
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
  c.setTextColor(kGrey, kBg);
  c.drawString("confidence", kW / 2, 232 + oy, 1);
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

}  // namespace

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

void displayBegin() {
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
