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

void displayBegin();
void displayDraw(const View& v);
