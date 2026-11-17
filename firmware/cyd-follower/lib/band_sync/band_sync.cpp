#include "band_sync.h"

#include <stdio.h>

namespace bandsync {

namespace {
constexpr uint8_t kMagic0 = 0x5C;
constexpr uint8_t kMagic1 = 0xBE;
constexpr uint8_t kFlagPlaying = 0x01;
constexpr uint8_t kFlagFreeRunning = 0x02;
constexpr uint8_t kFlagRushing = 0x04;
constexpr int kDriftShift = 4;

// AD types for lists of 128-bit service UUIDs.
constexpr uint8_t kAdIncomplete128 = 0x06;
constexpr uint8_t kAdComplete128 = 0x07;
}  // namespace

bool decodePayload(const uint8_t b[kPayloadLength], State& out) {
  if (b[0] != kMagic0 || b[1] != kMagic1) return false;
  if (b[2] != kProtocolVersion) return false;
  uint8_t check = 0xA5;
  for (size_t i = 0; i < kPayloadLength - 1; i++) check ^= b[i];
  if (check != b[15]) return false;

  State s;
  s.sessionId = static_cast<uint16_t>(b[3] << 8 | b[4]);
  s.sequence = b[5];
  const uint8_t flags = b[6];
  s.playing = flags & kFlagPlaying;
  s.freeRunning = flags & kFlagFreeRunning;
  s.rushing = flags & kFlagRushing;
  s.drift = static_cast<Drift>((flags >> kDriftShift) & 0x3);
  s.songIndex = b[7] == 255 ? -1 : b[7];
  s.target10 = static_cast<uint16_t>(b[8] << 8 | b[9]);
  s.heard10 = static_cast<uint16_t>(b[10] << 8 | b[11]);
  s.confidence = b[12];
  s.detailsVersion = static_cast<uint16_t>(b[13] << 8 | b[14]);
  out = s;
  return true;
}

bool decodeAirUuid(const uint8_t air[kPayloadLength], State& out) {
  uint8_t payload[kPayloadLength];
  for (size_t i = 0; i < kPayloadLength; i++) {
    payload[i] = air[kPayloadLength - 1 - i];
  }
  return decodePayload(payload, out);
}

bool findInAdvertisement(const uint8_t* data, size_t length, State& out) {
  size_t i = 0;
  while (i < length) {
    const uint8_t len = data[i];
    if (len == 0) break;  // padding
    if (i + 1 + len > length) break;  // truncated
    const uint8_t type = data[i + 1];
    if (type == kAdIncomplete128 || type == kAdComplete128) {
      const uint8_t* uuids = data + i + 2;
      const size_t count = (len - 1) / kPayloadLength;
      for (size_t u = 0; u < count; u++) {
        if (decodeAirUuid(uuids + u * kPayloadLength, out)) return true;
      }
    }
    i += 1 + len;
  }
  return false;
}

void sessionCode(uint16_t sessionId, char out[5]) {
  static const char kHex[] = "0123456789ABCDEF";
  for (int i = 0; i < 4; i++) {
    out[i] = kHex[(sessionId >> (12 - 4 * i)) & 0xF];
  }
  out[4] = '\0';
}

namespace {
const char* const kShapeNames[kIconShapes] = {
    "star",     "anchor", "heart",   "bolt",    // 0-3
    "moon",     "sun",    "cloud",   "key",     // 4-7
    "flame",    "leaf",   "paw",     "rocket",  // 8-11
    "umbrella", "bell",   "diamond", "drop",    // 12-15
};
const char* const kColourNames[kIconColours] = {"blue",   "green", "yellow",
                                                "orange", "pink",  "red"};
const uint32_t kColourRgb[kIconColours] = {0x40C4FF, 0x00E676, 0xFFEA00,
                                           0xFF9100, 0xE040FB, 0xFF5252};
}  // namespace

Icon sessionIcon(uint16_t sessionId) {
  const int index = sessionId % kIconCount;
  Icon icon;
  icon.shape = index % kIconShapes;
  icon.colour = index / kIconShapes;
  return icon;
}

const char* iconShapeName(uint8_t shape) {
  return shape < kIconShapes ? kShapeNames[shape] : "?";
}

const char* iconColourName(uint8_t colour) {
  return colour < kIconColours ? kColourNames[colour] : "?";
}

uint32_t iconColourRgb(uint8_t colour) {
  return colour < kIconColours ? kColourRgb[colour] : 0xFFFFFF;
}

void iconName(Icon icon, char* out, size_t n) {
  snprintf(out, n, "%s %s", iconColourName(icon.colour),
           iconShapeName(icon.shape));
}

bool Freshness::heard(const State& s, uint32_t nowMs) {
  if (hasNews_ && s.sequence == lastSequence_) return false;
  hasNews_ = true;
  lastSequence_ = s.sequence;
  lastNewsMs_ = nowMs;
  return true;
}

uint32_t Freshness::ageMs(uint32_t nowMs) const {
  return hasNews_ ? nowMs - lastNewsMs_ : UINT32_MAX;
}

Link Freshness::linkAt(uint32_t nowMs) const {
  const uint32_t age = ageMs(nowMs);
  if (age > kLostAfterMs) return Link::Lost;
  if (age > kStaleAfterMs) return Link::Stale;
  return Link::Live;
}

void Freshness::reset() {
  hasNews_ = false;
  lastSequence_ = 0;
  lastNewsMs_ = 0;
}

}  // namespace bandsync
