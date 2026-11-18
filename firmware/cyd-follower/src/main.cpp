// Beth band sync follower for the ESP32 "Cheap Yellow Display".
//
// Listens (passively) for a leader phone's band sync advertisement and
// mirrors its target and heard tempo on the screen. Like the app's follower,
// it connects to the leader once to read the playlist and song names, and
// again only when the advertised details version changes.

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <band_sync.h>
#include <band_sync_details.h>
#include <esp_sleep.h>
#include <string.h>

#include "display.h"
#include "leaders.h"
#include "touch.h"

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

// The leader picker, open when several leaders are nearby and we have to
// ask (like the phone follower's list), or when the user taps to switch.
bool pickerOpen = false;
uint32_t pickerTouchedMs = 0;  // closes by itself 20 s after this
constexpr uint32_t kPickerTimeoutMs = 20000;
// Give every nearby leader a chance to be heard before choosing.
constexpr uint32_t kSettleMs = 2000;
uint32_t scanStartedMs = 0;

void follow(uint16_t sessionId, const char* why) {
  followed = sessionId;
  following = true;
  nextNamesTryMs = 0;
  namesFailures = 0;
  char code[5];
  bandsync::sessionCode(followed, code);
  Serial.printf("following leader %s (%s)\n", code, why);
}

bool isLive(const LeaderInfo& l, uint32_t now) {
  return l.used && l.freshness.linkAt(now) == bandsync::Link::Live;
}

// Like the phone follower: join by itself only when there's no doubt.
// Keep the current leader until it's lost; then switch if exactly one
// other is live, or ask if there are several.
void chooseLeader(const LeaderInfo all[Leaders::kMax], uint32_t now) {
  bool currentOk = false;
  const LeaderInfo* onlyOther = nullptr;
  int others = 0;
  for (int i = 0; i < Leaders::kMax; i++) {
    const LeaderInfo& l = all[i];
    if (!l.used) continue;
    if (following && l.state.sessionId == followed) {
      currentOk = l.freshness.linkAt(now) != bandsync::Link::Lost;
    } else if (isLive(l, now)) {
      others++;
      onlyOther = &l;
    }
  }
  if (currentOk || now - scanStartedMs < kSettleMs) return;
  if (others == 1) {
    follow(onlyOther->state.sessionId,
           following ? "previous leader lost" : "only leader nearby");
    pickerOpen = false;
  } else if (others > 1 && !pickerOpen) {
    Serial.printf("%d leaders nearby: asking\n", others);
    pickerOpen = true;
    pickerTouchedMs = now;
  }
}

uint8_t signalBars(int rssi) {
  return rssi > -65 ? 3 : rssi > -78 ? 2 : rssi > -90 ? 1 : 0;
}

// Leaders that aren't lost, in a stable order (by code) so rows don't jump.
PickerView buildPicker(const LeaderInfo all[Leaders::kMax], uint32_t now,
                       bool currentOk) {
  PickerView p;
  p.canGoBack = currentOk;
  for (int i = 0; i < Leaders::kMax; i++) {
    const LeaderInfo& l = all[i];
    if (!l.used || l.freshness.linkAt(now) == bandsync::Link::Lost) continue;
    PickerEntry e;
    e.sessionId = l.state.sessionId;
    e.followed = following && l.state.sessionId == followed;
    e.live = l.freshness.linkAt(now) == bandsync::Link::Live;
    e.freeRunning = l.state.freeRunning;
    e.songIndex = l.state.songIndex;
    e.target10 = l.state.target10;
    e.heard10 = l.state.heard10;
    e.drift = l.state.drift;
    e.bars = signalBars(l.rssi);
    int at = p.count++;
    while (at > 0 && p.rows[at - 1].sessionId > e.sessionId) {
      p.rows[at] = p.rows[at - 1];
      at--;
    }
    p.rows[at] = e;
  }
  return p;
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

// Sleep: hold the screen, or a minute with no leader nearby. A tap wakes
// it (deep sleep ends in a fresh start, which finds the leader again).
constexpr uint32_t kHoldHintMs = 700;   // longer than this isn't a tap
constexpr uint32_t kSleepHoldMs = 2000;
constexpr uint32_t kNoLeaderSleepMs = 60000;
constexpr uint32_t kReleaseMs = 80;  // resistive panels drop out briefly

[[noreturn]] void goToSleep(const char* why) {
  Serial.printf("sleeping: %s\n", why);
  displayDrawMessage("Sleeping", "Tap the screen to wake");
  delay(1500);
  // A finger still on the panel would wake it straight away.
  const uint32_t start = millis();
  while (digitalRead(kTouchIrqPin) == LOW && millis() - start < 10000) {
    delay(20);
  }
  delay(100);

  scanPaused = true;
  NimBLEDevice::getScan()->stop();
  displayOff();
  esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(kTouchIrqPin), 0);
  Serial.flush();
  esp_deep_sleep_start();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  Serial.printf("\nBeth CYD follower %s (build %d, %s)%s\n", BETH_VERSION,
                BETH_BUILD, BETH_COMMIT,
                esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0
                    ? " (woken by a tap)"
                    : "");
  displayBegin();
  touchBegin();
  displayDraw(View());

  NimBLEDevice::init("");
  startScan();
  scanStartedMs = millis();
  Serial.println("scanning for leaders");
}

void loop() {
  static View shown;
  static PickerView shownPicker;
  static bool drawnOnce = false;
  static bool pickerShown = false;
  static int lastLoggedSeq = -1;
  // Touch: taps act on release; a long hold puts it to sleep. A press
  // already down at start-up (the tap that woke it) is ignored until it's
  // let go: it starts as "pressing" with no start time.
  static bool pressing = true;
  static uint32_t pressStartMs = 0;
  static uint32_t lastTouchedMs = 0;
  static TouchPoint pressAt{};
  static bool holdHintShown = false;
  static uint32_t lastLeaderMs = 0;

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
  const bool currentOk = v.hasLeader && v.link != bandsync::Link::Lost;
  const PickerView picker = buildPicker(all, now, currentOk);

  TouchPoint touch;
  const bool touched = touchRead(touch);
#ifdef TOUCH_DEBUG
  static uint32_t lastDebugMs = 0;
  if (touched && now - lastDebugMs > 150) {
    lastDebugMs = now;
    Serial.printf("held %d,%d (raw %u,%u)\n", touch.x, touch.y, touch.rawX,
                  touch.rawY);
  }
#endif
  bool tap = false;
  if (touched) {
    lastTouchedMs = now;
    if (!pressing) {
      pressing = true;
      pressStartMs = now;
      pressAt = touch;
    }
  } else if (pressing && now - lastTouchedMs > kReleaseMs) {
    pressing = false;
    tap = pressStartMs != 0 && !holdHintShown &&
          lastTouchedMs - pressStartMs < kHoldHintMs;
    if (holdHintShown) {
      holdHintShown = false;  // let go before sleeping: carry on
      drawnOnce = false;
      pickerShown = false;
    }
  }
  if (pressing && pressStartMs != 0) {
    const uint32_t held = now - pressStartMs;
    if (held >= kSleepHoldMs) goToSleep("held");
    if (held >= kHoldHintMs && !holdHintShown) {
      holdHintShown = true;
      displayDrawMessage("Keep holding to sleep", "Let go to cancel");
    }
  }

  // A minute with no leader nearby at all: sleep.
  bool anyLeader = false;
  for (int i = 0; i < Leaders::kMax; i++) {
    if (all[i].used && all[i].freshness.linkAt(now) != bandsync::Link::Lost) {
      anyLeader = true;
    }
  }
  if (anyLeader || lastLeaderMs == 0) lastLeaderMs = now;
  if (!pressing && now - lastLeaderMs > kNoLeaderSleepMs) {
    goToSleep("no leader for a minute");
  }
  if (holdHintShown) {
    delay(20);
    return;
  }

  if (tap) {
    const TouchPoint& touch = pressAt;
    Serial.printf("tap %d,%d (raw %u,%u)\n", touch.x, touch.y, touch.rawX,
                  touch.rawY);
    if (pickerOpen) {
      pickerTouchedMs = now;
      const int hit = pickerHit(picker, touch.x, touch.y);
      if (hit == kPickerBack) {
        pickerOpen = false;
      } else if (hit >= 0) {
        if (!following || picker.rows[hit].sessionId != followed) {
          follow(picker.rows[hit].sessionId, "chosen");
        }
        pickerOpen = false;
      }
    } else if (v.otherLeaders > 0) {
      pickerOpen = true;
      pickerTouchedMs = now;
    }
  }
  // An unused picker closes if there's someone to go back to.
  if (pickerOpen && currentOk && now - pickerTouchedMs > kPickerTimeoutMs) {
    pickerOpen = false;
  }
  // Nothing left to choose between.
  if (pickerOpen && picker.count == 0) pickerOpen = false;

  if (pickerOpen) {
    if (!pickerShown || picker != shownPicker) {
      displayDrawPicker(picker);
      shownPicker = picker;
      pickerShown = true;
      drawnOnce = false;
    }
    delay(20);
    return;
  }
  pickerShown = false;

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
  delay(20);
}
