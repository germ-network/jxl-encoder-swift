#include "registry.h"

#include <charconv>
#include <cstdint>
#include <limits>
#include <string_view>
#include <vector>

#include "lib/jxl/dec_ans.h"
#include "lib/jxl/enc_huffman_tree.h"
#include "lib/jxl/pack_signed.h"

namespace harness {
namespace {

bool ParseU32(std::string_view text, uint32_t *value) {
  const auto result =
      std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

bool ParseI32(std::string_view text, int32_t *value) {
  const auto result =
      std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

bool ParseHistogram(std::string_view text, std::vector<uint32_t> *counts) {
  size_t start = 0;
  while (start <= text.size()) {
    const size_t end = text.find(',', start);
    const size_t length =
        (end == std::string_view::npos ? text.size() : end) - start;
    uint32_t count = 0;
    if (length == 0 || !ParseU32(text.substr(start, length), &count))
      return false;
    counts->push_back(count);
    if (end == std::string_view::npos)
      break;
    start = end + 1;
  }
  return !counts->empty() && counts->size() <= 256;
}

int RunEntropyPrimitives(const std::vector<std::string> &args) {
  if (args.empty())
    return 2;
  if (args[0] == "uint") {
    if (args.size() < 5)
      return 2;
    uint32_t split = 0, msb = 0, lsb = 0;
    if (!ParseU32(args[1], &split) || !ParseU32(args[2], &msb) ||
        !ParseU32(args[3], &lsb) || split > 31 || msb > split ||
        lsb > split - msb)
      return 2;
    const jxl::HybridUintConfig config(split, msb, lsb);
    std::vector<int64_t> tokens, bit_counts, bits;
    for (size_t i = 4; i < args.size(); ++i) {
      uint32_t value = 0, token = 0, bit_count = 0, extra = 0;
      if (!ParseU32(args[i], &value))
        return 2;
      config.Encode(value, &token, &bit_count, &extra);
      tokens.push_back(token);
      bit_counts.push_back(bit_count);
      bits.push_back(extra);
    }
    SemanticDumpWriter dump;
    dump.Integers("entropy.uint.tokens", tokens);
    dump.Integers("entropy.uint.bit_counts", bit_counts);
    dump.Integers("entropy.uint.bits", bits);
    dump.Write(stdout);
    return 0;
  }
  if (args[0] == "signed") {
    if (args.size() < 2)
      return 2;
    std::vector<int64_t> values;
    for (size_t i = 1; i < args.size(); ++i) {
      int32_t value = 0;
      if (!ParseI32(args[i], &value))
        return 2;
      values.push_back(jxl::PackSigned(value));
    }
    SemanticDumpWriter dump;
    dump.Integers("entropy.signed.values", values);
    dump.Write(stdout);
    return 0;
  }
  if (args[0] == "huffman") {
    if (args.size() < 3)
      return 2;
    uint32_t limit = 0;
    if (!ParseU32(args[1], &limit) || limit == 0 || limit > 15 ||
        args.size() > 18)
      return 2;
    std::vector<int64_t> lengths, depths;
    for (size_t i = 2; i < args.size(); ++i) {
      std::vector<uint32_t> counts;
      if (!ParseHistogram(args[i], &counts))
        return 2;
      uint64_t total = 0;
      for (uint32_t count : counts) {
        if (count > std::numeric_limits<uint32_t>::max() - total)
          return 2;
        total += count;
      }
      size_t active = 0;
      for (uint32_t count : counts)
        active += count != 0;
      if (active == 0 || active > (size_t{1} << limit))
        return 2;
      std::vector<uint8_t> histogram_depths(counts.size(), 0);
      jxl::CreateHuffmanTree(counts.data(), counts.size(), limit,
                             histogram_depths.data());
      lengths.push_back(counts.size());
      for (uint8_t depth : histogram_depths)
        depths.push_back(depth);
    }
    SemanticDumpWriter dump;
    dump.Integers("entropy.huffman.lengths", lengths);
    dump.Integers("entropy.huffman.depths", depths);
    dump.Write(stdout);
    return 0;
  }
  return 2;
}

const RegisterSubcommand kRegister({"entropy-primitives",
                                    "uint|signed|huffman ...",
                                    RunEntropyPrimitives});

} // namespace
} // namespace harness
