// Band sync follower: decodes what a Beth leader broadcasts.
//
// A C++ port of the decoding half of lib/band_sync_protocol.dart (keep the
// two in step; test/band_sync_vectors.h is generated from the Dart encoder).
// No Arduino or BLE dependencies, so it builds and tests on the host.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace bandsync {

constexpr uint8_t kProtocolVersion = 1;
constexpr size_t kPayloadLength = 16;

// GATT service and details characteristic the leader serves for joining.
constexpr const char* kServiceUuid = "5cbe0001-7a3e-4b8e-9c61-2f0d5b9e4a10";
constexpr const char* kDetailsUuid = "5cbe0002-7a3e-4b8e-9c61-2f0d5b9e4a10";

enum class Drift : uint8_t { None = 0, OnTempo = 1, Drifting = 2, Off = 3 };

struct State {
  uint16_t sessionId = 0;
  uint8_t sequence = 0;
  bool playing = false;      // count-in metronome on
  bool freeRunning = false;  // no target tempo
  bool rushing = false;
  Drift drift = Drift::None;
  int16_t songIndex = -1;    // -1 = none
  uint16_t target10 = 0;     // target BPM x 10, 0 = none
  uint16_t heard10 = 0;      // detected BPM x 10, 0 = none
  uint8_t confidence = 0;    // x 255
  uint16_t detailsVersion = 0;

  bool hasTarget() const { return target10 != 0; }
  bool hasHeard() const { return heard10 != 0; }
};

// Decodes a payload in UUID-string order (byte 0 = 0x5C). False for anything
// that isn't a valid payload of a version we understand.
bool decodePayload(const uint8_t payload[kPayloadLength], State& out);

// Decodes a 128-bit UUID as it appears over the air (little-endian, so the
// payload's byte 0 is last).
bool decodeAirUuid(const uint8_t air[kPayloadLength], State& out);

// Searches raw advertisement data (length/type/value structures) for a
// band sync payload among its 128-bit service UUIDs.
bool findInAdvertisement(const uint8_t* data, size_t length, State& out);

// The session id as four upper-case hex digits plus a terminator.
void sessionCode(uint16_t sessionId, char out[5]);

// The leader's session icon (BandSyncIcon in lib/band_sync_icon.dart): one
// of 16 shapes x 6 colours, session id % 96, shape in the low part.
constexpr int kIconShapes = 16;
constexpr int kIconColours = 6;
constexpr int kIconCount = kIconShapes * kIconColours;

struct Icon {
  uint8_t shape = 0;   // 0..15, see iconShapeName
  uint8_t colour = 0;  // 0..5, see iconColourName
};

Icon sessionIcon(uint16_t sessionId);
const char* iconShapeName(uint8_t shape);    // "anchor"
const char* iconColourName(uint8_t colour);  // "orange"
uint32_t iconColourRgb(uint8_t colour);      // 0xRRGGBB
// "orange anchor", cut to fit n bytes.
void iconName(Icon icon, char* out, size_t n);

enum class Link : uint8_t { Live, Stale, Lost };

// When the follower last heard *new* data. The radio repeats the last
// advertisement, so only a new sequence number counts as news.
class Freshness {
 public:
  static constexpr uint32_t kStaleAfterMs = 4000;
  static constexpr uint32_t kLostAfterMs = 12000;

  // Records a received state; true if it was news.
  bool heard(const State& s, uint32_t nowMs);
  Link linkAt(uint32_t nowMs) const;
  // Milliseconds since the last news, or UINT32_MAX if never.
  uint32_t ageMs(uint32_t nowMs) const;
  void reset();

 private:
  bool hasNews_ = false;
  uint8_t lastSequence_ = 0;
  uint32_t lastNewsMs_ = 0;
};

}  // namespace bandsync
