#include <algorithm>
#include <vector>

// Semantic dump category for the retained AC entropy code tables.
#include <cstdio>
#include <cstdlib>
#include "decoded_frame.h"
#include "lib/jxl/ans_common.h"
#include "lib/jxl/dec_ans.h"
#include "lib/jxl/dec_huffman.h"
#include "registry.h"

namespace harness {
namespace {

[[noreturn]] void Reject(const char* reason) {
  std::fprintf(stderr, "dump ac_entropy: %s\n", reason);
  std::exit(1);
}

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& code = frame.state->code[0];
  const size_t count = code.uint_config.size();
  if (count == 0 || code.lz77.enabled)
    Reject("invalid table count or enabled AC LZ77");
  const auto& ac_map = frame.state->context_map[0];
  const size_t ac_contexts =
      frame.state->shared->num_histograms *
      frame.state->shared->block_ctx_map.NumACContexts();
  if (ac_map.size() < ac_contexts ||
      !std::all_of(ac_map.begin(), ac_map.begin() + ac_contexts,
                   [count](uint8_t value) { return value < count; }))
    Reject("invalid AC context map");

  std::vector<int64_t> config;
  for (const auto& item : code.uint_config) {
    config.push_back(item.split_exponent);
    config.push_back(item.msb_in_token);
    config.push_back(item.lsb_in_token);
  }
  out.Integers("ac_entropy.kind", {code.use_prefix_code ? 0 : 1});
  out.Integers("ac_entropy.table_count", {static_cast<int64_t>(count)});
  out.Integers("ac_entropy.uint_config", config);
  out.Integers("ac_entropy.lz77_enabled", {0});

  if (!code.use_prefix_code) {
    if (code.log_alpha_size > ANS_LOG_TAB_SIZE)
      Reject("invalid ANS alphabet setting");
    std::vector<int64_t> lengths;
    std::vector<int64_t> frequencies;
    const auto* entries = code.alias_tables.address<jxl::AliasTable::Entry>();
    if (entries == nullptr) Reject("missing ANS alias table");
    const size_t log_entry_size = ANS_LOG_TAB_SIZE - code.log_alpha_size;
    const size_t entry_mask = (1u << log_entry_size) - 1;
    for (size_t table = 0; table < count; ++table) {
      std::vector<int64_t> freq(ANS_MAX_ALPHABET_SIZE, 0);
      const auto* alias = entries + (table << code.log_alpha_size);
      for (size_t state = 0; state < ANS_TAB_SIZE; ++state) {
        const auto symbol = jxl::AliasTable::Lookup(
            alias, state, log_entry_size, entry_mask);
        if (symbol.value >= freq.size()) Reject("invalid ANS symbol index");
        ++freq[symbol.value];
      }
      const auto last = std::find_if(freq.rbegin(), freq.rend(),
                                     [](int64_t value) { return value != 0; });
      const size_t length = freq.size() - (last - freq.rbegin());
      if (length == 0) Reject("empty ANS table");
      lengths.push_back(length);
      frequencies.insert(frequencies.end(), freq.begin(), freq.begin() + length);
    }
    out.Integers("ac_entropy.ans.alphabet_lengths", lengths);
    out.Integers("ac_entropy.ans.frequencies", frequencies);
    return;
  }

  if (code.huffman_data.size() != count)
    Reject("invalid prefix table count");

  std::vector<int64_t> lengths, singletons, depths;
  for (size_t index = 0; index < count; ++index) {
    const auto& table = code.huffman_data[index].table_;
    if (table.size() < (1u << jxl::kHuffmanTableBits))
      Reject("invalid prefix table");
    std::vector<uint8_t> symbol_depths(PREFIX_MAX_ALPHABET_SIZE, 0);
    int singleton = -1;
    const size_t root_size = 1u << jxl::kHuffmanTableBits;
    for (size_t root = 0; root < root_size; ++root) {
      const auto& item = table[root];
      if (item.bits > PREFIX_MAX_BITS) Reject("invalid prefix code depth");
      if (item.value >= symbol_depths.size()) Reject("invalid prefix symbol index");
      if (item.bits == 0) {
        if (singleton >= 0 && singleton != item.value)
          Reject("inconsistent prefix singleton leaves");
        singleton = item.value;
        continue;
      }
      if (item.bits <= jxl::kHuffmanTableBits) {
        symbol_depths[item.value] = item.bits;
      } else {
        const size_t extra = item.bits - jxl::kHuffmanTableBits;
        const size_t offset = item.value;
        const size_t entries = 1u << extra;
        if (offset > table.size() - root ||
            entries > table.size() - root - offset)
          Reject("invalid prefix extension");
        const size_t extension = root + offset;
        for (size_t i = 0; i < entries; ++i) {
          const auto& leaf = table[extension + i];
          if (leaf.bits > PREFIX_MAX_BITS) Reject("invalid prefix code depth");
          if (leaf.value >= symbol_depths.size())
            Reject("invalid prefix symbol index");
          if (leaf.bits <= extra) {
            symbol_depths[leaf.value] = jxl::kHuffmanTableBits + leaf.bits;
          }
        }
      }
    }
    if (singleton >= 0) {
      const size_t length = static_cast<size_t>(singleton) + 1;
      lengths.push_back(length);
      singletons.push_back(singleton);
      depths.insert(depths.end(), length, 0);
    } else {
      const auto last = std::find_if(symbol_depths.rbegin(), symbol_depths.rend(),
                                     [](uint8_t value) { return value != 0; });
      const size_t length = symbol_depths.size() - (last - symbol_depths.rbegin());
      if (length == 0) Reject("empty prefix table");
      lengths.push_back(length);
      singletons.push_back(-1);
      depths.insert(depths.end(), symbol_depths.begin(), symbol_depths.begin() + length);
    }
  }
  out.Integers("ac_entropy.prefix.alphabet_lengths", lengths);
  out.Integers("ac_entropy.prefix.singleton_symbols", singletons);
  out.Integers("ac_entropy.prefix.depths", depths);
}

const RegisterDumpCategory kRegister({"ac_entropy", Dump});

}  // namespace
}  // namespace harness
