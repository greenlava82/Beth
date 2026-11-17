// Band sync details: the playlist and song names a follower reads once from
// the leader's GATT characteristic (BandSyncDetails in the app):
//   {"v":1,"playlist":"Friday Gig","songs":["Valerie","Ça va"]}
// No Arduino dependencies, so it builds and tests on the host.
#pragma once

#include <stddef.h>

#include <string>
#include <vector>

namespace bandsync {

struct Details {
  std::string playlist;            // UTF-8
  std::vector<std::string> songs;  // UTF-8, setlist order

  // The song at index, or nullptr when out of range (-1 = none).
  const std::string* songAt(int index) const {
    return index >= 0 && static_cast<size_t>(index) < songs.size()
               ? &songs[index]
               : nullptr;
  }
};

// Like BandSyncDetails.fromBytes: missing or odd fields become empty; false
// only when the data isn't a JSON object at all.
bool parseDetails(const char* json, size_t length, Details& out);

// UTF-8 text reduced to what the CYD's fonts can draw (printable ASCII):
// accented Latin letters lose their accents, typographic quotes and dashes
// become plain ones, other characters become '?', and control characters
// and runs of spaces collapse to one space.
std::string toDisplayText(const std::string& utf8);

}  // namespace bandsync
