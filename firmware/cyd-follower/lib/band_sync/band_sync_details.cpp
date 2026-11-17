#include "band_sync_details.h"

#include <stdint.h>

namespace bandsync {

namespace {

// A small, forgiving JSON reader: just enough for the details object.
class Reader {
 public:
  Reader(const char* s, size_t n) : p_(s), end_(s + n) {}

  void skipSpace() {
    while (p_ < end_ && (*p_ == ' ' || *p_ == '\t' || *p_ == '\n' ||
                         *p_ == '\r')) {
      p_++;
    }
  }

  bool consume(char c) {
    skipSpace();
    if (p_ < end_ && *p_ == c) {
      p_++;
      return true;
    }
    return false;
  }

  bool peek(char c) {
    skipSpace();
    return p_ < end_ && *p_ == c;
  }

  // Reads a string (cursor on the opening quote) as UTF-8.
  bool string(std::string& out) {
    out.clear();
    if (!consume('"')) return false;
    while (p_ < end_) {
      const char c = *p_++;
      if (c == '"') return true;
      if (c != '\\') {
        out += c;
        continue;
      }
      if (p_ >= end_) return false;
      const char e = *p_++;
      switch (e) {
        case 'n':
          out += '\n';
          break;
        case 't':
          out += '\t';
          break;
        case 'r':
          out += '\r';
          break;
        case 'b':
          out += '\b';
          break;
        case 'f':
          out += '\f';
          break;
        case 'u': {
          uint32_t cp;
          if (!hex4(cp)) return false;
          // A surrogate pair encodes one character outside the BMP.
          if (cp >= 0xD800 && cp <= 0xDBFF && end_ - p_ >= 6 && p_[0] == '\\' &&
              p_[1] == 'u') {
            p_ += 2;
            uint32_t lo;
            if (!hex4(lo)) return false;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          appendUtf8(out, cp);
          break;
        }
        default:  // \" \\ \/ and anything unexpected
          out += e;
      }
    }
    return false;  // unterminated
  }

  // Skips any value: string, number, literal, array or object.
  bool skipValue() {
    skipSpace();
    if (p_ >= end_) return false;
    if (*p_ == '"') {
      std::string ignored;
      return string(ignored);
    }
    if (*p_ == '[' || *p_ == '{') {
      const char close = *p_ == '[' ? ']' : '}';
      p_++;
      if (consume(close)) return true;
      do {
        if (close == '}') {
          std::string key;
          if (!string(key) || !consume(':')) return false;
        }
        if (!skipValue()) return false;
      } while (consume(','));
      return consume(close);
    }
    // Number or literal: up to the next delimiter.
    const char* start = p_;
    while (p_ < end_ && *p_ != ',' && *p_ != '}' && *p_ != ']' && *p_ != ' ' &&
           *p_ != '\n' && *p_ != '\r' && *p_ != '\t') {
      p_++;
    }
    return p_ > start;
  }

 private:
  bool hex4(uint32_t& out) {
    if (end_ - p_ < 4) return false;
    out = 0;
    for (int i = 0; i < 4; i++) {
      const char c = *p_++;
      out <<= 4;
      if (c >= '0' && c <= '9') {
        out |= c - '0';
      } else if (c >= 'a' && c <= 'f') {
        out |= c - 'a' + 10;
      } else if (c >= 'A' && c <= 'F') {
        out |= c - 'A' + 10;
      } else {
        return false;
      }
    }
    return true;
  }

  static void appendUtf8(std::string& out, uint32_t cp) {
    if (cp < 0x80) {
      out += static_cast<char>(cp);
    } else if (cp < 0x800) {
      out += static_cast<char>(0xC0 | (cp >> 6));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out += static_cast<char>(0xE0 | (cp >> 12));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (cp >> 18));
      out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  const char* p_;
  const char* end_;
};

// Base letters for U+00C0..U+017F (Latin-1 Supplement letters and Latin
// Extended-A); '\0' where there's no sensible single letter.
const char kLatin[] =
    // U+00C0..U+00FF
    "AAAAAAACEEEEIIII"
    "DNOOOOO\0OUUUUYTs"
    "aaaaaaaceeeeiiii"
    "dnooooo\0ouuuuyty"
    // U+0100..U+017F
    "AaAaAaCcCcCcCcDd"
    "DdEeEeEeEeEeGgGg"
    "GgGgHhHhIiIiIiIi"
    "IiJjJjKkkLlLlLlL"
    "lLlNnNnNnnNnOoOo"
    "OoOoRrRrRrSsSsSs"
    "SsTtTtTtUuUuUuUu"
    "UuUuWwYyYZzZzZzs";

// Decodes one UTF-8 character; invalid bytes come back as U+FFFD.
uint32_t nextCodePoint(const std::string& s, size_t& i) {
  const auto b = [&](size_t k) { return static_cast<uint8_t>(s[k]); };
  const uint8_t c = b(i++);
  if (c < 0x80) return c;
  int extra;
  uint32_t cp;
  if ((c & 0xE0) == 0xC0) {
    extra = 1;
    cp = c & 0x1F;
  } else if ((c & 0xF0) == 0xE0) {
    extra = 2;
    cp = c & 0x0F;
  } else if ((c & 0xF8) == 0xF0) {
    extra = 3;
    cp = c & 0x07;
  } else {
    return 0xFFFD;
  }
  for (int k = 0; k < extra; k++) {
    if (i >= s.size() || (b(i) & 0xC0) != 0x80) return 0xFFFD;
    cp = (cp << 6) | (b(i++) & 0x3F);
  }
  return cp;
}

const char* replacement(uint32_t cp) {
  switch (cp) {
    case 0x00C6:
      return "AE";
    case 0x00E6:
      return "ae";
    case 0x00DF:
      return "ss";
    case 0x0152:
      return "OE";
    case 0x0153:
      return "oe";
    case 0x00D7:
      return "x";
    case 0x2018:
    case 0x2019:
    case 0x201A:
    case 0x2032:
      return "'";
    case 0x201C:
    case 0x201D:
    case 0x201E:
    case 0x2033:
      return "\"";
    case 0x2010:
    case 0x2011:
    case 0x2012:
    case 0x2013:
    case 0x2014:
    case 0x2212:
      return "-";
    case 0x2026:
      return "...";
    case 0x00A0:
      return " ";
    default:
      return nullptr;
  }
}

}  // namespace

bool parseDetails(const char* json, size_t length, Details& out) {
  Reader r(json, length);
  if (!r.consume('{')) return false;
  Details d;
  if (!r.consume('}')) {
    do {
      std::string key;
      if (!r.string(key) || !r.consume(':')) break;
      if (key == "playlist" && r.peek('"')) {
        if (!r.string(d.playlist)) break;
      } else if (key == "songs" && r.peek('[')) {
        r.consume('[');
        if (!r.consume(']')) {
          bool ok = true;
          do {
            if (r.peek('"')) {
              std::string song;
              ok = r.string(song);
              if (ok) d.songs.push_back(song);
            } else {
              ok = r.skipValue();
              if (ok) d.songs.emplace_back();  // keep indexes aligned
            }
          } while (ok && r.consume(','));
          if (!ok || !r.consume(']')) break;
        }
      } else if (!r.skipValue()) {
        break;
      }
    } while (r.consume(','));
  }
  // Tolerant: keep whatever was read before any malformed tail.
  out = d;
  return true;
}

std::string toDisplayText(const std::string& utf8) {
  std::string out;
  out.reserve(utf8.size());
  bool lastSpace = true;  // also trims leading space
  size_t i = 0;
  while (i < utf8.size()) {
    const uint32_t cp = nextCodePoint(utf8, i);
    std::string piece;
    if (cp < 0x20 || cp == 0x7F) {
      piece = " ";
    } else if (cp < 0x7F) {
      piece = static_cast<char>(cp);
    } else if (const char* r = replacement(cp)) {
      piece = r;
    } else if (cp >= 0x00C0 && cp <= 0x017F && kLatin[cp - 0x00C0] != '\0') {
      piece = kLatin[cp - 0x00C0];
    } else if ((cp >= 0x0300 && cp <= 0x036F) || cp == 0xFE0F ||
               cp == 0x200D) {
      continue;  // combining accents, emoji variation selector, joiner
    } else {
      piece = "?";
    }
    for (char c : piece) {
      if (c == ' ') {
        if (lastSpace) continue;
        lastSpace = true;
      } else {
        lastSpace = false;
      }
      out += c;
    }
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

}  // namespace bandsync
