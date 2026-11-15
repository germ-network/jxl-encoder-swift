#include "registry.h"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <limits>
#include <string_view>
#include <utility>
#include <vector>

#include <jxl/memory_manager.h>

#include "lib/jxl/enc_ans.h"
#include "lib/jxl/enc_ans_params.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_bit_writer.h"
#include "lib/jxl/enc_entropy_coder.h"
#include "lib/jxl/fields.h"
#include "lib/jxl/memory_manager_internal.h"

namespace harness {
namespace {

bool ParseValue(std::string_view text, uint32_t* value) {
  const auto result =
      std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

int RunContextEntropy(const std::vector<std::string>& args) {
  if (args.empty() || args.size() > 1'000'000) return 2;
  std::vector<std::vector<jxl::Token>> tokens(1);
  for (const std::string& arg : args) {
    uint32_t value = 0;
    if (!ParseValue(arg, &value) || value > 255) return 2;
    tokens[0].emplace_back(0, value);
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::HistogramParams params;
  params.uint_method = jxl::HistogramParams::HybridUintMethod::kContextMap;
  auto estimated_tokens = tokens;
  jxl::EntropyEncodingData estimated_codes;
  auto cost = jxl::BuildAndEncodeHistograms(
      &manager, params, 1, estimated_tokens, &estimated_codes, nullptr,
      jxl::LayerType::Header, nullptr);
  if (!cost.ok()) return 1;
  const size_t estimated_cost = std::move(cost).value_();

  jxl::EntropyEncodingData codes;
  jxl::BitWriter writer(&manager);
  auto actual_cost = jxl::BuildAndEncodeHistograms(
      &manager, params, 1, tokens, &codes, &writer, jxl::LayerType::Header,
      nullptr);
  if (!actual_cost.ok()) return 1;
  jxl::WriteTokens(tokens[0], codes, 0, &writer);
  const size_t bit_count = writer.BitsWritten();
  writer.ZeroPadToByte();
  const auto bytes = writer.GetSpan();

  std::vector<int64_t> encoded_tokens;
  std::vector<int64_t> configs;
  std::vector<int64_t> context_map(estimated_codes.context_map.begin(),
                                   estimated_codes.context_map.end());
  std::vector<std::vector<uint32_t>> histogram_counts(
      estimated_codes.encoding_info.size());
  size_t context_count = estimated_codes.lz77.enabled ? 2 : 1;
  for (size_t context = 0; context < context_count; ++context) {
    const size_t histogram = estimated_codes.context_map.empty()
                                 ? 0
                                 : estimated_codes.context_map[context];
    if (histogram_counts[histogram].empty()) {
      histogram_counts[histogram].resize(256);
    }
  }
  for (const jxl::Token& token : estimated_tokens[0]) {
    encoded_tokens.insert(encoded_tokens.end(),
                          {token.context, token.value,
                           token.is_lz77_length ? 1 : 0});
    const size_t histogram = estimated_codes.context_map.empty()
                                 ? 0
                                 : estimated_codes.context_map[token.context];
    const jxl::HybridUintConfig& config =
        token.is_lz77_length ? estimated_codes.lz77.length_uint_config
                             : estimated_codes.uint_config[histogram];
    uint32_t symbol = 0, bit_count_unused = 0, bits_unused = 0;
    config.Encode(token.value, &symbol, &bit_count_unused, &bits_unused);
    if (token.is_lz77_length) symbol += estimated_codes.lz77.min_symbol;
    ++histogram_counts[histogram][symbol];
  }
  for (const auto& config : estimated_codes.uint_config) {
    configs.insert(configs.end(), {config.split_exponent, config.msb_in_token,
                                   config.lsb_in_token});
  }
  std::vector<int64_t> flattened_counts;
  std::vector<int64_t> table_values;
  std::vector<int64_t> table_lengths;
  for (size_t histogram = 0; histogram < histogram_counts.size(); ++histogram) {
    size_t alphabet_size =
        std::max_element(histogram_counts[histogram].begin(),
                         histogram_counts[histogram].end()) ==
                histogram_counts[histogram].end()
            ? 0
            : 256;
    while (alphabet_size > 0 && histogram_counts[histogram][alphabet_size - 1] == 0) {
      --alphabet_size;
    }
    table_lengths.push_back(alphabet_size);
    for (size_t symbol = 0; symbol < alphabet_size; ++symbol) {
      flattened_counts.push_back(histogram_counts[histogram][symbol]);
      const auto& info = estimated_codes.encoding_info[histogram][symbol];
      table_values.push_back(info.depth);
      table_values.push_back(info.freq_);
    }
  }
  std::vector<int64_t> serialized(bytes.begin(), bytes.end());
  SemanticDumpWriter dump;
  dump.Integers("entropy.context_entropy.entries", [&] {
    std::vector<int64_t> values;
    values.reserve(args.size());
    for (const std::string& arg : args) {
      uint32_t value = 0;
      ParseValue(arg, &value);
      values.push_back(value);
    }
    return values;
  }());
  dump.Integers("entropy.context_entropy.cost",
                {static_cast<int64_t>(estimated_cost)});
  dump.Integers("entropy.context_entropy.tokens", encoded_tokens);
  dump.Integers("entropy.context_entropy.context_map", context_map);
  dump.Integers("entropy.context_entropy.uint_configs", configs);
  dump.Integers("entropy.context_entropy.length_uint_config",
                {static_cast<int64_t>(estimated_codes.lz77.length_uint_config.split_exponent),
                 static_cast<int64_t>(estimated_codes.lz77.length_uint_config.msb_in_token),
                 static_cast<int64_t>(estimated_codes.lz77.length_uint_config.lsb_in_token)});
  dump.Integers("entropy.context_entropy.rle_enabled",
                {estimated_codes.lz77.enabled ? 1 : 0});
  dump.Integers("entropy.context_entropy.min_length_symbol",
                {estimated_codes.lz77.min_symbol});
  dump.Integers("entropy.context_entropy.min_length",
                {estimated_codes.lz77.min_length});
  dump.Integers("entropy.context_entropy.distance_context",
                {static_cast<int64_t>(
                    estimated_codes.lz77.nonserialized_distance_context)});
  dump.Integers("entropy.context_entropy.histogram_count",
                {static_cast<int64_t>(estimated_codes.encoding_info.size())});
  dump.Integers("entropy.context_entropy.histogram_lengths", table_lengths);
  dump.Integers("entropy.context_entropy.histogram_counts", flattened_counts);
  dump.Integers("entropy.context_entropy.tables", table_values);
  dump.Integers("entropy.context_entropy.use_prefix_code",
                {estimated_codes.use_prefix_code ? 1 : 0});
  dump.Integers("entropy.context_entropy.log_alpha_size",
                {static_cast<int64_t>(estimated_codes.log_alpha_size)});
  dump.Integers("entropy.context_entropy.bit_count",
                {static_cast<int64_t>(bit_count)});
  dump.Integers("entropy.context_entropy.bytes", serialized);
  dump.Write(stdout);
  return 0;
}

int RunContextEntropySingletonContexts(const std::vector<std::string>& args) {
  if (args.size() != 1) return 2;
  uint32_t majority_count = 0;
  if (!ParseValue(args[0], &majority_count) || majority_count < 100 ||
      majority_count > 1'000'000) return 2;
  std::vector<std::vector<jxl::Token>> tokens(majority_count + 1);
  for (size_t i = 0; i < majority_count; ++i) {
    tokens[i].emplace_back(0, 0);
  }
  tokens.back().emplace_back(1, 1);
  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::HistogramParams params;
  params.uint_method = jxl::HistogramParams::HybridUintMethod::kContextMap;
  jxl::EntropyEncodingData codes;
  auto cost = jxl::BuildAndEncodeHistograms(
      &manager, params, 2, tokens, &codes, nullptr,
      jxl::LayerType::Header, nullptr);
  if (!cost.ok()) return 1;
  SemanticDumpWriter dump;
  dump.Integers("entropy.context_entropy.token_count",
                {static_cast<int64_t>(majority_count) + 1});
  dump.Integers("entropy.context_entropy.rle_enabled",
                {codes.lz77.enabled ? 1 : 0});
  dump.Integers("entropy.context_entropy.histogram_counts",
                {static_cast<int64_t>(majority_count), 0, 0, 1});
  dump.Integers("entropy.context_entropy.use_prefix_code",
                {codes.use_prefix_code ? 1 : 0});
  dump.Write(stdout);
  return 0;
}

int RunContextEntropyRLEPattern(const std::vector<std::string>& args) {
  if (args.size() != 4) return 2;
  uint32_t groups = 0, run_length = 0, filler_count = 0, tail_length = 0;
  if (!ParseValue(args[0], &groups) || groups == 0 || groups > 10'000 ||
      !ParseValue(args[1], &run_length) || run_length < 4 || run_length > 4096 ||
      !ParseValue(args[2], &filler_count) || filler_count == 0 || filler_count > 255 ||
      !ParseValue(args[3], &tail_length) || tail_length > 4096) return 2;
  const uint64_t entry_count = static_cast<uint64_t>(groups) *
      (static_cast<uint64_t>(run_length) + filler_count) + tail_length;
  if (entry_count > 4'000'000) return 2;
  std::vector<std::vector<jxl::Token>> tokens(1);
  tokens[0].reserve(entry_count);
  for (uint32_t group = 0; group < groups; ++group) {
    for (uint32_t i = 0; i < run_length; ++i) tokens[0].emplace_back(0, 0);
    for (uint32_t value = 1; value <= filler_count; ++value) {
      tokens[0].emplace_back(0, value);
    }
  }
  for (uint32_t i = 0; i < tail_length; ++i) tokens[0].emplace_back(0, 0);
  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::HistogramParams params;
  params.uint_method = jxl::HistogramParams::HybridUintMethod::kContextMap;
  jxl::EntropyEncodingData codes;
  auto result = jxl::BuildAndEncodeHistograms(
      &manager, params, 1, tokens, &codes, nullptr,
      jxl::LayerType::Header, nullptr);
  if (!result.ok()) return 1;
  uint32_t hash = 2166136261u;
  for (const jxl::Token& token : tokens[0]) {
    for (uint32_t value : {token.context, token.value,
                           static_cast<uint32_t>(token.is_lz77_length)}) {
      hash = (hash ^ value) * 16777619u;
    }
  }
  SemanticDumpWriter dump;
  dump.Integers("entropy.context_entropy.input_count",
                {static_cast<int64_t>(entry_count)});
  dump.Integers("entropy.context_entropy.rle_enabled",
                {codes.lz77.enabled ? 1 : 0});
  dump.Integers("entropy.context_entropy.token_count",
                {static_cast<int64_t>(tokens[0].size())});
  dump.Integers("entropy.context_entropy.token_hash",
                {static_cast<int64_t>(hash)});
  dump.Write(stdout);
  return 0;
}

const RegisterSubcommand kRegister(
    {"context-entropy", "<entry>...", RunContextEntropy});
const RegisterSubcommand kSingletonContextsRegister(
    {"context-entropy-singleton-contexts", "<majority_count>",
     RunContextEntropySingletonContexts});
const RegisterSubcommand kRLEPatternRegister(
    {"context-entropy-rle-pattern", "<groups> <run_length> <filler_count> <tail_length>",
     RunContextEntropyRLEPattern});

}  // namespace
}  // namespace harness
