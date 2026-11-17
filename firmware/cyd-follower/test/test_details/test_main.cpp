// Host tests for the details parser and display text: pio test -e native

#include <band_sync_details.h>
#include <string.h>
#include <unity.h>

#include "../band_sync_vectors.h"

using bandsync::Details;
using bandsync::parseDetails;
using bandsync::toDisplayText;

void setUp() {}
void tearDown() {}

static bool parse(const char* json, Details& d) {
  return parseDetails(json, strlen(json), d);
}

static void test_parses_what_the_app_serves() {
  Details d;
  TEST_ASSERT_TRUE(parse(kBandSyncDetailsJson, d));
  TEST_ASSERT_EQUAL_STRING("Friday Gig \xE2\x80\x93 \xC3\x87" "a va",
                           d.playlist.c_str());
  TEST_ASSERT_EQUAL(5, d.songs.size());
  TEST_ASSERT_EQUAL_STRING("Valerie", d.songs[0].c_str());
  TEST_ASSERT_EQUAL_STRING("Don\xE2\x80\x99t Stop \"Me\" Now",
                           d.songs[1].c_str());
  TEST_ASSERT_EQUAL_STRING("Back\\slash", d.songs[2].c_str());
  TEST_ASSERT_EQUAL_STRING("", d.songs[4].c_str());
  TEST_ASSERT_EQUAL_STRING("Valerie", d.songAt(0)->c_str());
  TEST_ASSERT_NULL(d.songAt(5));
  TEST_ASSERT_NULL(d.songAt(-1));
}

static void test_escapes_and_whitespace() {
  Details d;
  TEST_ASSERT_TRUE(parse(
      " { \"songs\" : [ \"a\\u00e9b\" , \"\\ud83c\\udfb8\", \"x\\/y\\n\" ] ,"
      " \"playlist\" : \"P\" } ",
      d));
  TEST_ASSERT_EQUAL_STRING("P", d.playlist.c_str());
  TEST_ASSERT_EQUAL(3, d.songs.size());
  TEST_ASSERT_EQUAL_STRING("a\xC3\xA9" "b", d.songs[0].c_str());
  TEST_ASSERT_EQUAL_STRING("\xF0\x9F\x8E\xB8", d.songs[1].c_str());
  TEST_ASSERT_EQUAL_STRING("x/y\n", d.songs[2].c_str());
}

static void test_tolerant_like_the_app() {
  Details d;
  // Missing fields, unknown fields of every kind, a newer version.
  TEST_ASSERT_TRUE(parse(
      "{\"v\":2,\"extra\":{\"a\":[1,true,null,{\"b\":\"]\"}]},"
      "\"playlist\":\"X\",\"n\":-1.5e3}",
      d));
  TEST_ASSERT_EQUAL_STRING("X", d.playlist.c_str());
  TEST_ASSERT_EQUAL(0, d.songs.size());
  // Wrong types are ignored; non-string songs keep their place.
  TEST_ASSERT_TRUE(parse("{\"playlist\":7,\"songs\":[\"a\",3,\"c\"]}", d));
  TEST_ASSERT_EQUAL_STRING("", d.playlist.c_str());
  TEST_ASSERT_EQUAL(3, d.songs.size());
  TEST_ASSERT_EQUAL_STRING("c", d.songs[2].c_str());
  // A truncated read keeps what arrived.
  TEST_ASSERT_TRUE(parse("{\"playlist\":\"Y\",\"songs\":[\"a\",\"b", d));
  TEST_ASSERT_EQUAL_STRING("Y", d.playlist.c_str());
  TEST_ASSERT_EQUAL(1, d.songs.size());
  TEST_ASSERT_TRUE(parse("{}", d));
  // Not an object at all.
  TEST_ASSERT_FALSE(parse("nope", d));
  TEST_ASSERT_FALSE(parse("[1,2]", d));
  TEST_ASSERT_FALSE(parse("", d));
}

static void test_display_text() {
  // What the app serves, made drawable.
  Details d;
  parse(kBandSyncDetailsJson, d);
  TEST_ASSERT_EQUAL_STRING("Friday Gig - Ca va",
                           toDisplayText(d.playlist).c_str());
  TEST_ASSERT_EQUAL_STRING("Don't Stop \"Me\" Now",
                           toDisplayText(d.songs[1]).c_str());
  TEST_ASSERT_EQUAL_STRING("Unicode ?", toDisplayText(d.songs[3]).c_str());

  TEST_ASSERT_EQUAL_STRING("Strasse AEon Lodz",
                           toDisplayText("Stra\xC3\x9F" "e \xC3\x86on "
                                         "\xC5\x81\xC3\xB3" "d\xC5\xBA")
                               .c_str());
  TEST_ASSERT_EQUAL_STRING("Wait...", toDisplayText("Wait\xE2\x80\xA6").c_str());
  // Combining accent dropped; control characters and runs of spaces
  // collapse; ends trimmed.
  TEST_ASSERT_EQUAL_STRING("e a b",
                           toDisplayText("  e\xCC\x81 \t a\n\nb  ").c_str());
  // Broken UTF-8 doesn't run off the end.
  TEST_ASSERT_EQUAL_STRING("a?", toDisplayText("a\xC3").c_str());
  TEST_ASSERT_EQUAL_STRING("", toDisplayText("").c_str());
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_parses_what_the_app_serves);
  RUN_TEST(test_escapes_and_whitespace);
  RUN_TEST(test_tolerant_like_the_app);
  RUN_TEST(test_display_text);
  return UNITY_END();
}
