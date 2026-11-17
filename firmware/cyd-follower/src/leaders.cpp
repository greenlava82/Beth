#include "leaders.h"

void Leaders::heard(const bandsync::State& s, int rssi,
                    const NimBLEAddress& address, uint32_t nowMs) {
  portENTER_CRITICAL(&lock_);
  LeaderInfo* slot = nullptr;
  for (auto& l : slots_) {
    if (l.used && l.state.sessionId == s.sessionId) {
      slot = &l;
      break;
    }
  }
  if (slot == nullptr) {
    // A free slot, or else the one heard from least recently.
    for (auto& l : slots_) {
      if (!l.used) {
        slot = &l;
        break;
      }
      if (slot == nullptr || nowMs - l.lastSeenMs > nowMs - slot->lastSeenMs) {
        slot = &l;
      }
    }
    *slot = LeaderInfo();
    slot->used = true;
  }
  slot->state = s;
  slot->freshness.heard(s, nowMs);
  slot->rssi = rssi;
  slot->address = address;
  slot->lastSeenMs = nowMs;
  portEXIT_CRITICAL(&lock_);
}

void Leaders::snapshot(LeaderInfo out[kMax]) {
  portENTER_CRITICAL(&lock_);
  for (int i = 0; i < kMax; i++) out[i] = slots_[i];
  portEXIT_CRITICAL(&lock_);
}
