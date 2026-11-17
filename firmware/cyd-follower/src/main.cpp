// SCBeatWiz band sync follower for the ESP32 "Cheap Yellow Display".
//
// Listens (passively) for a leader phone's band sync advertisement and
// mirrors its target and heard tempo on the screen. Like the app's follower,
// it connects to the leader once to read the playlist and song names, and
// again only when the advertised details version changes.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <band_sync.h>
#include <band_sync_details.h>
#include <string.h>

#include "display.h"
#include "leaders.h"

namespace {

Leaders leaders;

// Session we're mirroring.
uint16_t followed = 0;
bool following = false;

// Paused while connecting for the details; the scan must not restart then.
volatile bool scanPaused = false;

// The names read from the followed leader.
struct NamesCache {
  bool valid = false;
  uint16_t sessionId = 0;
  uint16_t version = 0;
  bandsync::Details details;
};
NamesCache names;
uint32_t nextNamesTryMs = 0;
int namesFailures = 0;

// An Android leader gets a new random address every time it re-advertises
// (each update, up to four times a second), and the old one stops
// answering. So to connect, the scan callback catches the first
// advertisement of a new sequence and the loop connects to that address
// at once, while it's at its freshest.
portMUX_TYPE captureLock = portMUX_INITIALIZER_UNLOCKED;
bool capturing = false;
bool captured = false;
uint16_t captureSession = 0;
uint8_t captureAfterSequence = 0;
NimBLEAddress capturedAddress;

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* dev) override {
    const std::vector<uint8_t>& adv = dev->getPayload();
    bandsync::State s;
    if (!bandsync::findInAdvertisement(adv.data(), adv.size(), s)) return;
    leaders.heard(s, dev->getRSSI(), dev->getAddress(), millis());

    portENTER_CRITICAL(&captureLock);
    if (capturing && !captured && s.sessionId == captureSession &&
        s.sequence != captureAfterSequence) {
      capturedAddress = dev->getAddress();
      captured = true;
    }
    portEXIT_CRITICAL(&captureLock);
  }

  void onScanEnd(const NimBLEScanResults&, int reason) override {
    if (scanPaused) return;
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

// Waits for the leader's next new advertisement (up to 2 s, normally
// within its 1 s heartbeat), then connects to it, reads the details
// characteristic (a long read, so any length arrives whole) and
// disconnects. The scan is paused while connected.
bool readDetails(const bandsync::State& leader, bandsync::Details& out) {
  static NimBLEClient* client = nullptr;
  if (client == nullptr) {
    client = NimBLEDevice::createClient();
    // The address only lives until the leader's next update.
    client->setConnectTimeout(1500);
  }

  portENTER_CRITICAL(&captureLock);
  capturing = true;
  captured = false;
  captureSession = leader.sessionId;
  captureAfterSequence = leader.sequence;
  portEXIT_CRITICAL(&captureLock);
  const uint32_t start = millis();
  bool got = false;
  NimBLEAddress address;
  while (!got && millis() - start < 2000) {
    delay(2);
    portENTER_CRITICAL(&captureLock);
    got = captured;
    if (got) address = capturedAddress;
    portEXIT_CRITICAL(&captureLock);
  }
  portENTER_CRITICAL(&captureLock);
  capturing = false;
  portEXIT_CRITICAL(&captureLock);
  if (!got) {
    Serial.println("details read failed (no fresh advertisement)");
    return false;
  }

  scanPaused = true;
  NimBLEDevice::getScan()->stop();
  const uint32_t connectStart = millis();
  bool ok = false;
  const char* step = "connect";
  if (client->connect(address)) {
    step = "service";
    NimBLERemoteService* service = client->getService(bandsync::kServiceUuid);
    NimBLERemoteCharacteristic* details =
        service ? service->getCharacteristic(bandsync::kDetailsUuid) : nullptr;
    if (details != nullptr) {
      step = "read";
      const NimBLEAttValue value = details->readValue();
      ok = value.size() > 0 &&
           bandsync::parseDetails(reinterpret_cast<const char*>(value.data()),
                                  value.size(), out);
      Serial.printf("details: %u bytes\n", static_cast<unsigned>(value.size()));
    }
    client->disconnect();
  }
  Serial.printf("details read %s (%s; waited %lu ms, connected in %lu ms)\n",
                ok ? "ok" : "failed", step,
                static_cast<unsigned long>(connectStart - start),
                static_cast<unsigned long>(millis() - connectStart));

  scanPaused = false;
  NimBLEDevice::getScan()->start(0, false, true);
  return ok;
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
    nextNamesTryMs = 0;
    namesFailures = 0;
    char code[5];
    bandsync::sessionCode(followed, code);
    Serial.printf("following leader %s (rssi %d)\n", code, best->rssi);
  }
}

bool namesCurrentFor(const bandsync::State& s) {
  return names.valid && names.sessionId == s.sessionId &&
         names.version == s.detailsVersion;
}

void copyText(char* out, size_t n, const std::string* utf8) {
  if (utf8 == nullptr) {
    out[0] = '\0';
    return;
  }
  strlcpy(out, bandsync::toDisplayText(*utf8).c_str(), n);
}

// Fills the names into the view, from a cache for this leader only (names
// from an earlier leader would be wrong). While a newer version is being
// read, the previous names stay up.
void fillNames(View& v) {
  if (!names.valid || names.sessionId != v.state.sessionId) return;
  const auto& d = names.details;
  copyText(v.playlist, sizeof v.playlist, &d.playlist);
  v.songCount = static_cast<int>(d.songs.size());
  copyText(v.song, sizeof v.song, d.songAt(v.state.songIndex));
  if (v.state.songIndex >= 0) {
    copyText(v.next, sizeof v.next, d.songAt(v.state.songIndex + 1));
  }
}

void logState(const LeaderInfo& l) {
  const auto& s = l.state;
  char code[5];
  bandsync::sessionCode(s.sessionId, code);
  Serial.printf(
      "%s #%3u song=%d target=%u.%u heard=%u.%u conf=%.2f drift=%u "
      "play=%d free=%d rush=%d details=%04x rssi=%d from %s\n",
      code, s.sequence, s.songIndex, s.target10 / 10, s.target10 % 10,
      s.heard10 / 10, s.heard10 % 10, s.confidence / 255.0,
      static_cast<unsigned>(s.drift), s.playing, s.freeRunning, s.rushing,
      s.detailsVersion, l.rssi, l.address.toString().c_str());
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
  const LeaderInfo* leader = nullptr;
  for (int i = 0; i < Leaders::kMax; i++) {
    const LeaderInfo& l = all[i];
    if (!l.used) continue;
    if (following && l.state.sessionId == followed) {
      leader = &l;
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

  // Names: read once per leader and details version, only while the
  // leader is live (it's in range), backing off after failures.
  const bool wantNames = leader != nullptr &&
                         v.link == bandsync::Link::Live &&
                         !namesCurrentFor(leader->state) &&
                         static_cast<int32_t>(now - nextNamesTryMs) >= 0;
  if (v.hasLeader) fillNames(v);
  if (wantNames) {
    v.readingDetails = true;
    displayDraw(v);  // show "Getting song names..." during the read
    bandsync::Details d;
    if (readDetails(leader->state, d)) {
      names.valid = true;
      names.sessionId = leader->state.sessionId;
      names.version = leader->state.detailsVersion;
      names.details = d;
      namesFailures = 0;
      Serial.printf("names: \"%s\", %u songs\n",
                    bandsync::toDisplayText(d.playlist).c_str(),
                    static_cast<unsigned>(d.songs.size()));
    } else {
      namesFailures++;
      nextNamesTryMs = millis() + (namesFailures < 5 ? 1000 : 30000);
    }
    drawnOnce = false;  // redraw with the result
    return;
  }

  if (!drawnOnce || v != shown) {
    displayDraw(v);
    shown = v;
    drawnOnce = true;
  }
  delay(50);
}
