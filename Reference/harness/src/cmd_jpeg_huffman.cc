#include "registry.h"

#include <charconv>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "lib/jxl/jpeg/enc_jpeg_huffman_decode.h"

namespace harness {
namespace {

bool ParseList(std::string_view text, std::vector<uint32_t>* values) {
  while (!text.empty()) {
    const size_t comma = text.find(',');
    const std::string_view item = text.substr(0, comma);
    uint32_t value = 0;
    const auto result = std::from_chars(item.data(), item.data() + item.size(), value);
    if (result.ec != std::errc{} || result.ptr != item.data() + item.size()) return false;
    values->push_back(value);
    if (comma == std::string_view::npos) break;
    text.remove_prefix(comma + 1);
  }
  return true;
}

int Run(const std::vector<std::string>& args) {
  if (args.size() != 2) return 2;
  std::vector<uint32_t> counts;
  std::vector<uint32_t> symbols;
  if (!ParseList(args[0], &counts) || !ParseList(args[1], &symbols) || counts.size() != 16)
    return 2;

  size_t total = 0;
  size_t max_depth = 1;
  int64_t space = 1 << 16;
  for (size_t i = 0; i < counts.size(); ++i) {
    if (counts[i] > 255) return 2;
    if (counts[i] != 0) max_depth = i + 1;
    total += counts[i];
    space -= static_cast<int64_t>(counts[i]) * (1 << (15 - i));
  }
  if (total != symbols.size() || total > 256) return 2;
  std::vector<bool> seen(256);
  for (uint32_t symbol : symbols) {
    if (symbol > 255 || seen[symbol]) return 2;
    seen[symbol] = true;
  }
  std::vector<uint32_t> source_counts(17);
  for (size_t i = 0; i < counts.size(); ++i) source_counts[i + 1] = counts[i];
  ++source_counts[max_depth];
  symbols.push_back(256);
  space -= 1 << (16 - max_depth);
  if (space < 0) return 2;

  jxl::jpeg::HuffmanTableEntry lut[jxl::jpeg::kJpegHuffmanLutSize];
  jxl::jpeg::BuildJpegHuffmanTable(source_counts.data(), symbols.data(), lut);
  for (const auto& entry : lut) std::printf("%u\t%u\n", entry.bits, entry.value);
  return 0;
}

}  // namespace

static RegisterSubcommand register_jpeg_huffman(
    {"jpeg-huffman", "<16 comma-separated counts> <comma-separated symbols>", Run});

}  // namespace harness
