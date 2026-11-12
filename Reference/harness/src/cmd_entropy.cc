#include "registry.h"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string_view>

#include <jxl/memory_manager.h>

#include "lib/jxl/enc_ans.h"
#include "lib/jxl/enc_ans_params.h"
#include "lib/jxl/enc_cluster.h"
#include "lib/jxl/enc_context_map.h"
#include "lib/jxl/dec_ans.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/fields.h"
#include "lib/jxl/base/bits.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/memory_manager_internal.h"

namespace harness {
namespace {

bool ParseInt(std::string_view text, int* value) {
  const auto result = std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc{} && result.ptr == text.data() + text.size();
}

bool ParseCounts(const std::string& text, std::vector<int>* counts) {
  std::stringstream stream(text);
  std::string value;
  uint64_t total = 0;
  while (std::getline(stream, value, ',')) {
    int count = 0;
    if (!ParseInt(value, &count) || count < 0) return false;
    if (static_cast<uint64_t>(count) >
        std::numeric_limits<uint32_t>::max() - total) return false;
    total += static_cast<uint64_t>(count);
    counts->push_back(count);
  }
  return !counts->empty();
}

int RunHistogram(const std::vector<std::string>& args) {
	if (args.size() < 2) return 2;
  int log_alpha_size = 0;
  if (!ParseInt(args[0], &log_alpha_size) || log_alpha_size < 5 ||
      log_alpha_size > 8) return 2;
  jxl::HistogramParams::ANSHistogramStrategy strategy;
	if (args[1] == "fast") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kFast;
	} else if (args[1] == "approximate") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kApproximate;
	} else if (args[1] == "precise") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kPrecise;
  } else {
    return 2;
  }

	jxl::Histogram histogram(args.size() - 2);
	if (histogram.counts.size() > (size_t{1} << log_alpha_size) ||
	    histogram.counts.size() > 256) return 2;
	uint64_t total_count = 0;
	for (size_t i = 2; i < args.size(); ++i) {
    int count = 0;
    if (!ParseInt(args[i], &count) || count < 0) return 2;
		if (static_cast<uint64_t>(count) >
		    std::numeric_limits<uint32_t>::max() - total_count) return 2;
		total_count += static_cast<uint64_t>(count);
		histogram.counts[i - 2] = count;
    histogram.total_count += count;
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::EntropyEncodingData codes;
  codes.use_prefix_code = false;
  codes.log_alpha_size = log_alpha_size;
  const size_t alphabet_size = histogram.alphabet_size();
  codes.encoding_info.resize(1);
  codes.encoding_info[0].resize(std::max<size_t>(1, alphabet_size));
  jxl::BitWriter writer(&manager);
  size_t cost = 0;
  const jxl::Status status = writer.WithMaxBits(
      256 + alphabet_size * 24, jxl::LayerType::Header, nullptr,
      [&]() -> jxl::Status {
        JXL_ASSIGN_OR_RETURN(
            cost, codes.BuildAndStoreANSEncodingData(
                      &manager, strategy, histogram, &writer));
        return true;
      });
  if (!status) return 1;
  const size_t bit_count = writer.BitsWritten();
  writer.ZeroPadToByte();
  const auto bytes = writer.GetSpan();
  size_t bit_offset = 0;
  auto read_bits = [&](size_t count) {
    size_t value = 0;
    for (size_t i = 0; i < count; ++i, ++bit_offset) {
      value |= size_t((bytes[bit_offset / 8] >> (bit_offset % 8)) & 1) << i;
    }
    return value;
  };
  int serialized_method = 0;
  int serialized_shift = -1;
  if (read_bits(1) == 1) {
    serialized_method = 1;
  } else if (read_bits(1) == 0) {
    const size_t upper_bound_log = jxl::FloorLog2Nonzero(ANS_LOG_TAB_SIZE + 1);
    size_t log = 0;
    for (; log < upper_bound_log; ++log) {
      if (read_bits(1) == 0) break;
    }
    const size_t method = (read_bits(log) | (size_t{1} << log));
    serialized_method = 2;
    serialized_shift = static_cast<int>(method - 1);
  }
  std::vector<int64_t> normalized;
  std::vector<int64_t> frequencies;
  std::vector<int64_t> reverse_map;
  for (size_t i = 0; i < alphabet_size; ++i) {
    const auto& info = codes.encoding_info[0][i];
    frequencies.push_back(info.freq_);
    for (uint16_t value : info.reverse_map_) reverse_map.push_back(value);
  }
  for (size_t i = 0; i < alphabet_size; ++i) {
    normalized.push_back(codes.encoding_info[0][i].freq_);
  }
  std::vector<int64_t> serialized(bytes.begin(), bytes.end());
  SemanticDumpWriter dump;
  dump.Integers("entropy.histogram.normalized", normalized);
  dump.Integers("entropy.histogram.log_alpha_size", {log_alpha_size});
  dump.Integers("entropy.histogram.serialized_method", {serialized_method});
  dump.Integers("entropy.histogram.serialized_shift", {serialized_shift});
  dump.Integers("entropy.histogram.alphabet_size", {static_cast<int64_t>(alphabet_size)});
  dump.Integers("entropy.histogram.freqs", frequencies);
  dump.Integers("entropy.histogram.reverse_map", reverse_map);
  dump.Integers("entropy.histogram.bit_count", {static_cast<int64_t>(bit_count)});
  dump.Integers("entropy.histogram.bytes", serialized);
  dump.Write(stdout);
  return 0;
}

int RunClusters(const std::vector<std::string>& args) {
	if (args.size() < 3) return 2;
	const bool best = args[0] == "best";
	if (!best && args[0] != "fast") return 2;
  int limit = 0;
	if (!ParseInt(args[1], &limit) || limit <= 0) return 2;
  std::vector<jxl::Histogram> input;
  std::vector<int64_t> lengths;
	uint64_t total_count = 0;
	for (size_t i = 2; i < args.size(); ++i) {
    std::vector<int> counts;
    if (!ParseCounts(args[i], &counts)) return 2;
    for (int count : counts) {
      if (static_cast<uint64_t>(count) >
          std::numeric_limits<uint32_t>::max() - total_count) return 2;
      total_count += static_cast<uint64_t>(count);
    }
    input.emplace_back(counts.size());
    for (size_t symbol = 0; symbol < counts.size(); ++symbol) {
      input.back().counts[symbol] = counts[symbol];
    }
    input.back().Condition();
    lengths.push_back(counts.size());
  }
  jxl::HistogramParams params;
  params.clustering = best ? jxl::HistogramParams::ClusteringType::kBest
                           : jxl::HistogramParams::ClusteringType::kFast;
  std::vector<jxl::Histogram> clusters;
  std::vector<uint32_t> symbols;
  if (!jxl::ClusterHistograms(params, input, limit, &clusters, &symbols)) return 1;
  std::vector<int64_t> cluster_lengths;
  std::vector<int64_t> totals;
  std::vector<int64_t> values;
  int64_t input_total = 0;
  int64_t output_total = 0;
  for (const auto& histogram : input) input_total += histogram.total_count;
  for (const auto& cluster : clusters) {
    const size_t length = cluster.alphabet_size();
    cluster_lengths.push_back(length);
    totals.push_back(cluster.total_count);
    output_total += cluster.total_count;
    for (size_t i = 0; i < length; ++i) values.push_back(cluster.counts[i]);
  }
  std::vector<int64_t> map(symbols.begin(), symbols.end());
  SemanticDumpWriter dump;
  dump.Integers("entropy.clusters.count", {static_cast<int64_t>(clusters.size())});
  dump.Integers("entropy.clusters.map", map);
  dump.Integers("entropy.clusters.alphabet_lengths", cluster_lengths);
  dump.Integers("entropy.clusters.total_counts", totals);
  dump.Integers("entropy.clusters.histogram_counts", values);
  dump.Integers("entropy.clusters.input_total_count", {input_total});
  dump.Integers("entropy.clusters.output_total_count", {output_total});
  dump.Write(stdout);
  return 0;
}

int RunContextMap(const std::vector<std::string>& args) {
  if (args.size() < 2) return 2;
  int num_histograms = 0;
  if (!ParseInt(args[0], &num_histograms) || num_histograms < 1 ||
      num_histograms > 255) return 2;
  auto mtf_marker = std::find(args.begin() + 1, args.end(), "--mtf");
  const bool measure_mtf = mtf_marker != args.end();
  const size_t entries_end = measure_mtf
                                 ? static_cast<size_t>(mtf_marker - args.begin())
                                 : args.size();
  std::vector<uint8_t> entries;
  for (size_t i = 1; i < entries_end; ++i) {
    int entry = 0;
    if (!ParseInt(args[i], &entry) || entry < 0 || entry >= num_histograms)
      return 2;
    entries.push_back(static_cast<uint8_t>(entry));
  }
  if (entries.empty() || entries.size() > 1'000'000) return 2;
  std::vector<uint8_t> mtf_entries;
  if (measure_mtf) {
    for (auto it = mtf_marker + 1; it != args.end(); ++it) {
      int entry = 0;
      if (!ParseInt(*it, &entry) || entry < 0 || entry >= num_histograms)
        return 2;
      mtf_entries.push_back(static_cast<uint8_t>(entry));
    }
    if (mtf_entries.size() != entries.size()) return 2;
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::BitWriter writer(&manager);
  if (!writer.WithMaxBits(3 + entries.size() * 24, jxl::LayerType::Header,
                          nullptr, [&] {
                            return jxl::EncodeContextMap(
                                entries, num_histograms, &writer,
                                jxl::LayerType::Header, nullptr);
                          })) return 1;
  const size_t bit_count = writer.BitsWritten();
  writer.ZeroPadToByte();
  const auto bytes = writer.GetSpan();
  size_t bit_offset = 0;
  auto read_bits = [&](size_t count) {
    size_t value = 0;
    for (size_t i = 0; i < count; ++i, ++bit_offset) {
      value |= size_t((bytes[bit_offset / 8] >> (bit_offset % 8)) & 1) << i;
    }
    return value;
  };
  int simple = 0;
  int use_mtf = 0;
  int entry_bits = -1;
  int use_prefix_code = -1;
  if (num_histograms == 1) {
    simple = 1;
    entry_bits = 0;
  } else {
    simple = static_cast<int>(read_bits(1));
    if (simple) {
      entry_bits = static_cast<int>(read_bits(2));
    } else {
      use_mtf = static_cast<int>(read_bits(1));
      std::vector<uint8_t> encoded(bytes.begin(), bytes.end());
      jxl::BitReader reader(encoded);
      reader.ReadBits(2);
      jxl::LZ77Params lz77;
      if (!jxl::Bundle::Read(&reader, &lz77)) return 1;
      use_prefix_code = static_cast<int>(reader.ReadBits(1));
      if (!reader.Close()) return 1;
    }
  }
  auto inspect_candidate = [&](const std::vector<uint8_t>& values,
                               size_t* cost, size_t* token_count) -> bool {
    jxl::HistogramParams params;
    params.uint_method = jxl::HistogramParams::HybridUintMethod::kContextMap;
    std::vector<std::vector<jxl::Token>> tokens(1);
    for (uint8_t value : values) tokens[0].emplace_back(0, value);
    jxl::EntropyEncodingData codes;
    auto result = jxl::BuildAndEncodeHistograms(
        &manager, params, 1, tokens, &codes, nullptr,
        jxl::LayerType::Header, nullptr);
    if (!result.ok()) return false;
    *cost = std::move(result).value_();
    *token_count = tokens[0].size();
    return true;
  };
  size_t raw_cost = 0;
  size_t mtf_cost = 0;
  size_t raw_token_count = 0;
  size_t mtf_token_count = 0;
  if (measure_mtf &&
      (!inspect_candidate(entries, &raw_cost, &raw_token_count) ||
       !inspect_candidate(mtf_entries, &mtf_cost, &mtf_token_count))) return 1;
  int64_t token_count = -1;
  if (simple == 0) {
    if (use_mtf == 1) {
      if (measure_mtf) token_count = static_cast<int64_t>(mtf_token_count);
    } else {
      if (!measure_mtf &&
          !inspect_candidate(entries, &raw_cost, &raw_token_count)) return 1;
      token_count = static_cast<int64_t>(raw_token_count);
    }
  }
  std::vector<int64_t> serialized(bytes.begin(), bytes.end());
  SemanticDumpWriter dump;
  dump.Integers("entropy.context_map.entries",
                std::vector<int64_t>(entries.begin(), entries.end()));
  dump.Integers("entropy.context_map.num_histograms", {num_histograms});
  dump.Integers("entropy.context_map.simple", {simple});
  dump.Integers("entropy.context_map.entry_bits", {entry_bits});
  dump.Integers("entropy.context_map.use_mtf", {use_mtf});
  dump.Integers("entropy.context_map.use_prefix_code", {use_prefix_code});
  dump.Integers("entropy.context_map.token_count", {token_count});
  dump.Integers("entropy.context_map.bit_count", {static_cast<int64_t>(bit_count)});
  dump.Integers("entropy.context_map.bytes", serialized);
  if (measure_mtf) {
    dump.Integers("entropy.context_map.raw_cost", {static_cast<int64_t>(raw_cost)});
    dump.Integers("entropy.context_map.mtf_cost", {static_cast<int64_t>(mtf_cost)});
    const size_t simple_entry_bits =
        jxl::CeilLog2Nonzero(static_cast<size_t>(num_histograms));
    const int64_t simple_cost = simple_entry_bits < 4
                                    ? static_cast<int64_t>(simple_entry_bits * entries.size())
                                    : -1;
    dump.Integers("entropy.context_map.simple_cost", {simple_cost});
    dump.Integers("entropy.context_map.mtf_entries",
                  std::vector<int64_t>(mtf_entries.begin(), mtf_entries.end()));
  }
  dump.Write(stdout);
  return 0;
}

int RunEntropy(const std::vector<std::string>& args) {
  if (args.empty()) return 2;
  if (args[0] == "histogram") {
    return RunHistogram(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "cluster") {
    return RunClusters(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "context-map") {
    return RunContextMap(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  return 2;
}

const RegisterSubcommand kRegister({
    "entropy", "histogram|cluster ...",
    RunEntropy});

}  // namespace
}  // namespace harness
