// Host tests for the band sync decoder: pio test -e native

#include <band_sync.h>
#include <string.h>
#include <unity.h>

#include "../band_sync_vectors.h"

using bandsync::Drift;
using bandsync::Freshness;
using bandsync::Link;
using bandsync::State;

void setUp() {}
void tearDown() {}

static void test_vectors_decode_like_the_app() {
  for (int i = 0; i < kBandSyncVectorCount; i++) {
    const BandSyncVector& v = kBandSyncVectors[i];
    State s;
    const bool ok = bandsync::decodeAirUuid(v.air, s);
    TEST_ASSERT_EQUAL_MESSAGE(v.valid, ok, v.name);
    if (!ok) continue;
    TEST_ASSERT_EQUAL_UINT16_MESSAGE(v.sessionId, s.sessionId, v.name);
    TEST_ASSERT_EQUAL_UINT8_MESSAGE(v.sequence, s.sequence, v.name);
    TEST_ASSERT_EQUAL_MESSAGE(v.playing, s.playing, v.name);
    TEST_ASSERT_EQUAL_MESSAGE(v.freeRunning, s.freeRunning, v.name);
    TEST_ASSERT_EQUAL_MESSAGE(v.rushing, s.rushing, v.name);
    TEST_ASSERT_EQUAL_UINT8_MESSAGE(v.drift, static_cast<uint8_t>(s.drift),
                                    v.name);
    TEST_ASSERT_EQUAL_INT16_MESSAGE(v.songIndex, s.songIndex, v.name);
    TEST_ASSERT_EQUAL_UINT16_MESSAGE(v.target10, s.target10, v.name);
    TEST_ASSERT_EQUAL_UINT16_MESSAGE(v.heard10, s.heard10, v.name);
    TEST_ASSERT_EQUAL_UINT8_MESSAGE(v.confidence, s.confidence, v.name);
    TEST_ASSERT_EQUAL_UINT16_MESSAGE(v.detailsVersion, s.detailsVersion,
                                     v.name);
  }
}

static void test_string_order_is_rejected_over_the_air() {
  // A decoder that forgets to reverse the bytes must not "work" by luck.
  const BandSyncVector& full = kBandSyncVectors[0];
  uint8_t wrongOrder[16];
  for (int i = 0; i < 16; i++) wrongOrder[i] = full.air[15 - i];
  State s;
  TEST_ASSERT_FALSE(bandsync::decodeAirUuid(wrongOrder, s));
  TEST_ASSERT_TRUE(bandsync::decodePayload(wrongOrder, s));
  TEST_ASSERT_EQUAL_UINT16(0x4F2A, s.sessionId);
}

static void test_finds_payload_in_advertisement() {
  const BandSyncVector& full = kBandSyncVectors[0];
  // Flags, a 16-bit UUID list, then the complete 128-bit list.
  uint8_t adv[31];
  size_t n = 0;
  const uint8_t head[] = {0x02, 0x01, 0x06, 0x03, 0x03, 0x0D, 0x18,
                          0x11, 0x07};
  memcpy(adv, head, sizeof(head));
  n = sizeof(head);
  memcpy(adv + n, full.air, 16);
  n += 16;
  State s;
  TEST_ASSERT_TRUE(bandsync::findInAdvertisement(adv, n, s));
  TEST_ASSERT_EQUAL_UINT16(0x4F2A, s.sessionId);
  TEST_ASSERT_EQUAL_UINT16(1214, s.heard10);

  // Truncated: the length byte claims more than there is.
  TEST_ASSERT_FALSE(bandsync::findInAdvertisement(adv, n - 1, s));
  // Nothing but flags.
  TEST_ASSERT_FALSE(bandsync::findInAdvertisement(head, 3, s));
}

static void test_session_code() {
  char code[5];
  bandsync::sessionCode(0x4F2A, code);
  TEST_ASSERT_EQUAL_STRING("4F2A", code);
  bandsync::sessionCode(0x0001, code);
  TEST_ASSERT_EQUAL_STRING("0001", code);
}

static void test_freshness() {
  State s;
  s.sequence = 200;
  Freshness f;
  TEST_ASSERT_EQUAL(Link::Lost, f.linkAt(0));

  TEST_ASSERT_TRUE(f.heard(s, 1000));
  TEST_ASSERT_EQUAL(Link::Live, f.linkAt(4000));
  // The same advertisement repeated by the radio isn't news...
  TEST_ASSERT_FALSE(f.heard(s, 4000));
  TEST_ASSERT_EQUAL(Link::Stale, f.linkAt(6000));
  TEST_ASSERT_EQUAL(Link::Lost, f.linkAt(14000));
  // ...but the next heartbeat is.
  s.sequence = 201;
  TEST_ASSERT_TRUE(f.heard(s, 15000));
  TEST_ASSERT_EQUAL(Link::Live, f.linkAt(15000));

  // Sequence 0 is news on a fresh tracker, and millis() wrap is harmless.
  f.reset();
  s.sequence = 0;
  TEST_ASSERT_TRUE(f.heard(s, UINT32_MAX - 500));
  TEST_ASSERT_EQUAL(Link::Live, f.linkAt(1000));
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_vectors_decode_like_the_app);
  RUN_TEST(test_string_order_is_rejected_over_the_air);
  RUN_TEST(test_finds_payload_in_advertisement);
  RUN_TEST(test_session_code);
  RUN_TEST(test_freshness);
  return UNITY_END();
}
