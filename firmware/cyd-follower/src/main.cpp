// SCBeatWiz band sync follower for the ESP32 "Cheap Yellow Display".
//
// Listens (passively, no connection) for a leader phone's band sync
// advertisement and mirrors its target and heard tempo on the screen.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <band_sync.h>

#include "display.h"
#include "leaders.h"

namespace {

Leaders leaders;

// Session we're mirroring; 0 = none chosen yet.
uint16_t followed = 0;
bool following = false;

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* dev) override {
    const std::vector<uint8_t>& adv = dev->getPayload();
    bandsync::State s;
    if (!bandsync::findInAdvertisement(adv.data(), adv.size(), s)) return;
    leaders.heard(s, dev->getRSSI(), millis());
  }

  void onScanEnd(const NimBLEScanResults&, int reason) override {
    Serial.printf("scan ended (%d), restarting\n", reason);
    NimBLEDevice::getScan()->start(0, false, true);
  }
};

ScanCallbacks scanCallbacks;

void startScan() {
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(&scanCallbacks, /*wantDuplicates=*/true);
  // Every repeat of an advertisement matters (that's how we see new
  // sequence numbers), so no duplicate filtering and no stored results.
  scan->setDuplicateFilter(0);
  scan->setMaxResults(0);
  scan->setActiveScan(false);
  scan->setInterval(100);
  scan->setWindow(100);
  scan->start(0, false, true);  // forever
}

// Picks who to follow: keep the current leader unless it's been lost and
// another one is live; otherwise the strongest live leader.
void chooseLeader(const LeaderInfo all[Leaders::kMax], uint32_t now) {
  const LeaderInfo* current = nullptr;
  const LeaderInfo* best = nullptr;
  for (int i = 0; i < Leaders::kMax; i++) {
    const LeaderInfo& l = all[i];
    if (!l.used) continue;
    if (following && l.state.sessionId == followed) current = &l;
    if (l.freshness.linkAt(now) == bandsync::Link::Live &&
        (best == nullptr || l.rssi > best->rssi)) {
      best = &l;
    }
  }
  const bool currentLost =
      current == nullptr ||
      current->freshness.linkAt(now) == bandsync::Link::Lost;
  if (best != nullptr && (!following || currentLost) &&
      (!following || best->state.sessionId != followed)) {
    followed = best->state.sessionId;
    following = true;
    char code[5];
    bandsync::sessionCode(followed, code);
    Serial.printf("following leader %s (rssi %d)\n", code, best->rssi);
  }
}

void logState(const LeaderInfo& l) {
  const auto& s = l.state;
  char code[5];
  bandsync::sessionCode(s.sessionId, code);
  Serial.printf(
      "%s #%3u song=%d target=%u.%u heard=%u.%u conf=%.2f drift=%u "
      "play=%d free=%d rush=%d details=%04x rssi=%d\n",
      code, s.sequence, s.songIndex, s.target10 / 10, s.target10 % 10,
      s.heard10 / 10, s.heard10 % 10, s.confidence / 255.0,
      static_cast<unsigned>(s.drift), s.playing, s.freeRunning, s.rushing,
      s.detailsVersion, l.rssi);
}

}  // namespace

void setup() {
  Serial.begin(115200);
  Serial.println("\nSCBeatWiz CYD follower");
  displayBegin();
  displayDraw(View());

  NimBLEDevice::init("");
  startScan();
  Serial.println("scanning for leaders");
}

void loop() {
  static View shown;
  static bool drawnOnce = false;
  static int lastLoggedSeq = -1;

  const uint32_t now = millis();
  LeaderInfo all[Leaders::kMax];
  leaders.snapshot(all);
  chooseLeader(all, now);

  View v;
  for (int i = 0; i < Leaders::kMax; i++) {
    const LeaderInfo& l = all[i];
    if (!l.used) continue;
    if (following && l.state.sessionId == followed) {
      v.hasLeader = true;
      v.state = l.state;
      v.link = l.freshness.linkAt(now);
      const uint32_t age = l.freshness.ageMs(now);
      // Banners count seconds; while live the age isn't shown, so don't
      // let it cause redraws.
      v.ageSec = v.link == bandsync::Link::Live ? 0 : age / 1000;
      if (l.state.sequence != lastLoggedSeq) {
        lastLoggedSeq = l.state.sequence;
        logState(l);
      }
    } else if (l.freshness.linkAt(now) != bandsync::Link::Lost) {
      v.otherLeaders++;
    }
  }

  if (!drawnOnce || v != shown) {
    displayDraw(v);
    shown = v;
    drawnOnce = true;
  }
  delay(50);
}
