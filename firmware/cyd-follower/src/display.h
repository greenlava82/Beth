// Drawing the follower screen on the CYD's 320x240 TFT, plus the RGB LED.
#pragma once

#include <band_sync.h>

// What the screen shows; the UI redraws only when this changes.
struct View {
  bool hasLeader = false;
  bandsync::State state;
  bandsync::Link link = bandsync::Link::Lost;
  uint32_t ageSec = 0;  // since the last news, for the banners
  int otherLeaders = 0;

  // From the leader's details, already reduced to drawable ASCII; empty
  // until they've been read.
  char playlist[48] = "";
  char song[64] = "";
  char next[64] = "";
  int songCount = 0;  // 0 = unknown
  bool readingDetails = false;

  bool operator==(const View& o) const;
  bool operator!=(const View& o) const { return !(*this == o); }
};

// The leader picker: shown when several leaders are nearby.
struct PickerEntry {
  uint16_t sessionId = 0;
  bool followed = false;
  bool live = false;
  bool freeRunning = false;
  int16_t songIndex = -1;
  uint16_t target10 = 0;
  uint16_t heard10 = 0;
  bandsync::Drift drift = bandsync::Drift::None;
  uint8_t bars = 0;  // signal strength, 0-3
};

struct PickerView {
  static constexpr int kMaxRows = 4;
  int count = 0;
  PickerEntry rows[kMaxRows];
  bool canGoBack = false;  // already following someone

  bool operator==(const PickerView& o) const;
  bool operator!=(const PickerView& o) const { return !(*this == o); }
};

// What a tap on the picker hit.
constexpr int kPickerBack = -2;
constexpr int kPickerNothing = -1;
int pickerHit(const PickerView& p, int x, int y);  // row index, or above

void displayBegin();
void displayDraw(const View& v);
void displayDrawPicker(const PickerView& p);

// A full-screen message (sleep prompts).
void displayDrawMessage(const char* title, const char* detail);

// Before deep sleep: panel asleep, backlight and LED off, and those pins
// held so they stay off while the chip sleeps.
void displayOff();
