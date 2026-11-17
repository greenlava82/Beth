// Leaders heard nearby, keyed by session id (a leader's Bluetooth address
// can rotate, its session id doesn't). Written from the BLE task, read from
// the UI loop: every access goes through the lock.
#pragma once

#include <Arduino.h>
#include <NimBLEAddress.h>
#include <band_sync.h>

struct LeaderInfo {
  bool used = false;
  bandsync::State state;
  bandsync::Freshness freshness;
  int rssi = 0;
  uint32_t lastSeenMs = 0;  // any advertisement, news or not
  // Where it was last heard from; can change while the session stays.
  NimBLEAddress address;
};

class Leaders {
 public:
  static constexpr int kMax = 4;

  // From the scan callback.
  void heard(const bandsync::State& s, int rssi,
             const NimBLEAddress& address, uint32_t nowMs);

  // A consistent copy for drawing.
  void snapshot(LeaderInfo out[kMax]);

 private:
  portMUX_TYPE lock_ = portMUX_INITIALIZER_UNLOCKED;
  LeaderInfo slots_[kMax];
};
