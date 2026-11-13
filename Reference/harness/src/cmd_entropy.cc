#include "registry.h"

#include <algorithm>
#include <array>
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
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/coeff_order.h"
#include "lib/jxl/enc_entropy_coder.h"
#include "lib/jxl/enc_params.h"
#include "lib/jxl/frame_header.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/modular/encoding/enc_encoding.h"
#include "lib/jxl/modular/encoding/encoding.h"
#include "lib/jxl/modular/encoding/enc_ma.h"
#include "lib/jxl/modular/encoding/ma_common.h"
#include "lib/jxl/modular/modular_image.h"

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
  int64_t token_count_status = 0;
  if (simple == 0) {
    if (use_mtf == 1) {
      if (measure_mtf) {
        token_count = static_cast<int64_t>(mtf_token_count);
        token_count_status = 2;
      } else {
        token_count_status = 3;
      }
    } else {
      if (!measure_mtf &&
          !inspect_candidate(entries, &raw_cost, &raw_token_count)) return 1;
      token_count = static_cast<int64_t>(raw_token_count);
      token_count_status = 1;
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
  dump.Integers("entropy.context_map.token_count_status", {token_count_status});
  dump.Integers("entropy.context_map.bit_count", {static_cast<int64_t>(bit_count)});
  dump.Integers("entropy.context_map.bytes", serialized);
  if (measure_mtf) {
    dump.Integers("entropy.context_map.raw_cost", {static_cast<int64_t>(raw_cost)});
    dump.Integers("entropy.context_map.mtf_cost", {static_cast<int64_t>(mtf_cost)});
    dump.Integers("entropy.context_map.raw_token_count",
                  {static_cast<int64_t>(raw_token_count)});
    dump.Integers("entropy.context_map.mtf_token_count",
                  {static_cast<int64_t>(mtf_token_count)});
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

int RunTree(const std::vector<std::string>& args) {
  if (args.size() != 4) return 2;
  int kind = 0;
  int total_pixels = 0;
  int bitdepth = 0;
  int prevprop = 0;
  if (!ParseInt(args[0], &kind) || kind < 0 || kind > 6 ||
      !ParseInt(args[1], &total_pixels) || total_pixels <= 0 ||
      !ParseInt(args[2], &bitdepth) || bitdepth < 1 || bitdepth > 32 ||
      !ParseInt(args[3], &prevprop) || prevprop < 0 || prevprop > 1) return 2;
  const auto tree_kind = static_cast<jxl::ModularOptions::TreeKind>(kind);
  const jxl::Tree tree = jxl::PredefinedTree(
      tree_kind, static_cast<size_t>(total_pixels), bitdepth, prevprop);
  std::vector<jxl::Token> tokens;
  jxl::Tree decoder_tree;
  if (!jxl::TokenizeTree(tree, &tokens, &decoder_tree)) return 1;
  std::vector<int64_t> nodes;
  for (const auto& node : decoder_tree) {
    nodes.insert(nodes.end(), {
        node.property, node.splitval, node.lchild, node.rchild,
        static_cast<int>(node.predictor), node.predictor_offset,
        node.multiplier});
  }
  std::vector<int64_t> serialized_tokens;
  for (const auto& token : tokens) {
    serialized_tokens.push_back(token.context);
    serialized_tokens.push_back(token.value);
  }
  SemanticDumpWriter dump;
  dump.Integers("entropy.tree.kind", {kind});
  dump.Integers("entropy.tree.total_pixels", {total_pixels});
  dump.Integers("entropy.tree.bitdepth", {bitdepth});
  dump.Integers("entropy.tree.prevprop", {prevprop});
  dump.Integers("entropy.tree.node_count", {static_cast<int64_t>(decoder_tree.size())});
  dump.Integers("entropy.tree.nodes", nodes);
  dump.Integers("entropy.tree.token_count", {static_cast<int64_t>(tokens.size())});
  dump.Integers("entropy.tree.tokens", serialized_tokens);
  dump.Write(stdout);
  return 0;
}

int RunModular(const std::vector<std::string>& args) {
  if (args.size() < 10) return 2;
  int width = 0, height = 0, bitdepth = 0, kind = 0, total_pixels = 0;
  int prevprop = 0, group_id = 0;
  if (!ParseInt(args[0], &width) || width < 1 || width > 32 ||
      !ParseInt(args[1], &height) || height < 1 || height > 32 ||
      !ParseInt(args[2], &bitdepth) || bitdepth != 8 ||
      !ParseInt(args[3], &kind) || (kind != 5 && kind != 6) ||
      !ParseInt(args[4], &total_pixels) || total_pixels < 1 ||
      !ParseInt(args[5], &prevprop) || prevprop != 0 ||
      !ParseInt(args[6], &group_id) || group_id < 0 || group_id > 255 ||
      args.size() != 10 + static_cast<size_t>(3 * width * height)) return 2;

  std::array<int, 3> channel_order{};
  std::array<bool, 3> seen{};
  for (size_t i = 0; i < channel_order.size(); ++i) {
    if (!ParseInt(args[7 + i], &channel_order[i]) || channel_order[i] < 0 ||
        channel_order[i] >= 3 || seen[channel_order[i]]) return 2;
    seen[channel_order[i]] = true;
  }
  std::array<std::vector<int32_t>, 3> samples;
  for (auto& channel : samples) channel.resize(width * height);
  size_t arg_index = 10;
  for (size_t channel = 0; channel < samples.size(); ++channel) {
    for (int i = 0; i < width * height; ++i) {
      int value = 0;
      if (!ParseInt(args[arg_index++], &value) || value < -32768 ||
          value > 32767) return 2;
      samples[channel][i] = value;
    }
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  auto image_or = jxl::Image::Create(&manager, width, height, bitdepth, 3);
  if (!image_or.ok()) return 1;
  jxl::Image image = std::move(image_or).value_();
  image.nb_meta_channels = 0;
  for (size_t channel = 0; channel < channel_order.size(); ++channel) {
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        image.channel[channel].Row(y)[x] =
            samples[channel_order[channel]][y * width + x];
      }
    }
  }

  jxl::ModularOptions options;
  options.max_chan_size = std::max(width, height);
  if (kind == 5) {
    options.predictor = jxl::Predictor::Weighted;
    options.wp_tree_mode = jxl::ModularOptions::TreeMode::kWPOnly;
    options.tree_kind = jxl::ModularOptions::TreeKind::kWPFixedDC;
  }
  const auto predefined_tree = jxl::PredefinedTree(
      static_cast<jxl::ModularOptions::TreeKind>(kind), total_pixels,
      bitdepth, prevprop);
  std::vector<jxl::Token> tree_tokens;
  jxl::Tree tree;
  if (!jxl::TokenizeTree(predefined_tree, &tree_tokens, &tree)) return 1;
  jxl::GroupHeader header;
  std::vector<jxl::Token> tokens;
  size_t image_width = 0;
  if (!jxl::ModularCompress(image, options, group_id, tree, header, tokens,
                            &image_width) || image_width != size_t(width)) {
    return 1;
  }

  std::vector<int64_t> serialized_tokens;
  serialized_tokens.reserve(tokens.size() * 2);
  for (const auto& token : tokens) {
    serialized_tokens.push_back(token.context);
    serialized_tokens.push_back(token.value);
  }
  SemanticDumpWriter dump;
  dump.Integers("entropy.modular.bitdepth", {bitdepth});
  dump.Integers("entropy.modular.group_id", {group_id});
  dump.Integers("entropy.modular.height", {height});
  dump.Integers("entropy.modular.token_count",
                {static_cast<int64_t>(tokens.size())});
  dump.Integers("entropy.modular.tokens", serialized_tokens);
  dump.Integers("entropy.modular.total_pixels", {total_pixels});
  dump.Integers("entropy.modular.tree_kind", {kind});
  dump.Integers("entropy.modular.channel_order",
                {channel_order[0], channel_order[1], channel_order[2]});
  dump.Integers("entropy.modular.prevprop", {prevprop});
  dump.Integers("entropy.modular.tree_node_count",
                {static_cast<int64_t>(tree.size())});
  std::vector<int64_t> serialized_tree_nodes;
  for (const auto& node : tree) {
    serialized_tree_nodes.insert(serialized_tree_nodes.end(), {
        node.property, node.splitval, node.lchild, node.rchild,
        static_cast<int>(node.predictor), node.predictor_offset,
        node.multiplier});
  }
  dump.Integers("entropy.modular.tree_nodes", serialized_tree_nodes);
  std::vector<int64_t> serialized_tree_tokens;
  for (const auto& token : tree_tokens) {
    serialized_tree_tokens.push_back(token.context);
    serialized_tree_tokens.push_back(token.value);
  }
  dump.Integers("entropy.modular.tree_tokens", serialized_tree_tokens);
  dump.Integers("entropy.modular.width", {width});
  dump.Write(stdout);
  return 0;
}

int RunACMetadata(const std::vector<std::string>& args) {
  if (args.size() < 4) return 2;
  int width = 0, height = 0, first_blocks = 0;
  if (!ParseInt(args[0], &width) || width < 1 || width > 64 ||
      !ParseInt(args[1], &height) || height < 1 || height > 64 ||
      !ParseInt(args[2], &first_blocks) || first_blocks != width * height) {
    return 2;
  }
  const int cmap_width = (width + 7) / 8;
  const int cmap_height = (height + 7) / 8;
  const size_t cmap_count = static_cast<size_t>(cmap_width * cmap_height);
  const size_t block_count = static_cast<size_t>(first_blocks);
  const size_t epf_count = static_cast<size_t>(width * height);
  if (args.size() != 3 + cmap_count * 2 + block_count * 2 + epf_count) return 2;
  std::array<std::vector<int32_t>, 5> values;
  const std::array<size_t, 5> counts = {
      cmap_count, cmap_count, block_count, block_count, epf_count};
  size_t cursor = 3;
  for (size_t channel = 0; channel < values.size(); ++channel) {
    values[channel].resize(counts[channel]);
    for (auto& value : values[channel]) {
      if (!ParseInt(args[cursor++], &value)) return 2;
      if (channel < 2 && (value < -128 || value > 127)) return 2;
      if (channel == 2 && (value < 0 || value > 63)) return 2;
      if (channel == 3 && (value < 1 || value > 256)) return 2;
      if (channel == 4 && (value < 0 || value > 4)) return 2;
    }
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  auto image_or = jxl::Image::Create(&manager, width, height, 8, 4);
  if (!image_or.ok()) return 1;
  jxl::Image image = std::move(image_or).value_();
  image.nb_meta_channels = 0;
  auto create_channel = [&](size_t index, size_t channel_width,
                            size_t channel_height, int hshift,
                            int vshift) -> bool {
    auto channel = jxl::Channel::Create(&manager, channel_width, channel_height,
                                        hshift, vshift);
    if (!channel.ok()) return false;
    image.channel[index] = std::move(channel).value_();
    return true;
  };
  if (!create_channel(0, cmap_width, cmap_height, 3, 3) ||
      !create_channel(1, cmap_width, cmap_height, 3, 3) ||
      !create_channel(2, block_count, 2, 0, 0) ||
      !create_channel(3, width, height, 0, 0)) return 1;
  for (size_t i = 0; i < cmap_count; ++i) {
    image.channel[0].Row(i / cmap_width)[i % cmap_width] = values[0][i];
    image.channel[1].Row(i / cmap_width)[i % cmap_width] = values[1][i];
  }
  for (size_t i = 0; i < block_count; ++i) {
    image.channel[2].Row(0)[i] = values[2][i];
    image.channel[2].Row(1)[i] = values[3][i] - 1;
  }
  for (size_t i = 0; i < epf_count; ++i) {
    image.channel[3].Row(i / width)[i % width] = values[4][i];
  }

  const size_t total_pixels = cmap_count * 2 + block_count * 2 + epf_count;
  const auto tree = jxl::PredefinedTree(
      jxl::ModularOptions::TreeKind::kACMeta, total_pixels, 8, 0);
  std::vector<jxl::Token> tree_tokens;
  jxl::Tree decoder_tree;
  if (!jxl::TokenizeTree(tree, &tree_tokens, &decoder_tree)) return 1;
  jxl::ModularOptions options;
  options.max_chan_size = 0xFFFFFF;
  options.predictor = jxl::Predictor::Gradient;
  options.wp_tree_mode = jxl::ModularOptions::TreeMode::kGradientOnly;
  options.tree_kind = jxl::ModularOptions::TreeKind::kACMeta;
  jxl::GroupHeader header;
  std::vector<jxl::Token> tokens;
  size_t image_width = 0;
  if (!jxl::ModularCompress(image, options, 0, decoder_tree, header, tokens,
                            &image_width) || image_width != block_count ||
      tokens.size() != cmap_count * 2 + block_count * 2 + epf_count) {
    return 1;
  }
  const std::array<std::string_view, 5> names = {
      "cfl_ytox", "cfl_ytob", "acs", "quant_field", "epf"};
  SemanticDumpWriter dump;
  dump.Integers("entropy.ac_metadata.width", {width});
  dump.Integers("entropy.ac_metadata.height", {height});
  dump.Integers("entropy.ac_metadata.total_pixels",
                {static_cast<int64_t>(total_pixels)});
  dump.Integers("entropy.ac_metadata.tree_node_count",
                {static_cast<int64_t>(decoder_tree.size())});
  std::vector<int64_t> tree_nodes;
  for (const auto& node : decoder_tree) {
    tree_nodes.insert(tree_nodes.end(), {
        node.property, node.splitval, node.lchild, node.rchild,
        static_cast<int>(node.predictor), node.predictor_offset,
        node.multiplier});
  }
  dump.Integers("entropy.ac_metadata.tree_nodes", tree_nodes);
  size_t token_offset = 0;
  for (size_t channel = 0; channel < names.size(); ++channel) {
    std::vector<int64_t> channel_tokens;
    for (size_t i = 0; i < counts[channel]; ++i) {
      channel_tokens.push_back(tokens[token_offset].context);
      channel_tokens.push_back(tokens[token_offset].value);
      ++token_offset;
    }
    dump.Integers("entropy.ac_metadata." + std::string(names[channel]) +
                      ".tokens",
                  channel_tokens);
  }
  dump.Write(stdout);
  return 0;
}

int RunTreeEntropy(const std::vector<std::string>& args) {
  if (args.size() < 4) return 2;
  int speed_tier = 0, decoding_tier = 0, extra_dc_precision = 0;
  int token_count = 0;
  if (!ParseInt(args[0], &speed_tier) || speed_tier != 6 ||
      !ParseInt(args[1], &decoding_tier) || decoding_tier != 0 ||
      !ParseInt(args[2], &extra_dc_precision) || extra_dc_precision != 0 ||
      !ParseInt(args[3], &token_count) || token_count < 1 || token_count > 4096 ||
      args.size() != 4 + static_cast<size_t>(token_count * 2)) return 2;
  std::vector<jxl::Token> tree_tokens;
  tree_tokens.reserve(token_count);
  for (int i = 0; i < token_count; ++i) {
    int context = 0, value = 0;
    if (!ParseInt(args[4 + 2 * i], &context) || context < 0 ||
        context >= jxl::kNumTreeContexts ||
        !ParseInt(args[5 + 2 * i], &value) || value < 0) return 2;
    tree_tokens.emplace_back(context, value);
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::CompressParams cparams;
  cparams.speed_tier = jxl::SpeedTier::kCheetah;
  cparams.decoding_speed_tier = decoding_tier;
  cparams.modular_mode = false;
  const auto params = jxl::HistogramParams::ForModular(
      cparams, {static_cast<uint8_t>(extra_dc_precision)}, false);
  std::vector<std::vector<jxl::Token>> token_streams(1, tree_tokens);
  jxl::EntropyEncodingData codes;
  jxl::BitWriter writer(&manager);
  size_t cost = 0;
  const jxl::Status status = writer.WithMaxBits(
      1 << 20, jxl::LayerType::ModularTree, nullptr,
      [&]() -> jxl::Status {
        JXL_ASSIGN_OR_RETURN(
            cost, jxl::BuildAndEncodeHistograms(
                      &manager, params, jxl::kNumTreeContexts, token_streams,
                      &codes, &writer, jxl::LayerType::ModularTree, nullptr));
        JXL_RETURN_IF_ERROR(jxl::WriteTokens(
            token_streams[0], codes, 0, &writer, jxl::LayerType::ModularTree,
            nullptr));
        return true;
      });
  if (!status) return 1;

  std::vector<int64_t> serialized_tokens;
  for (const auto& token : token_streams[0]) {
    serialized_tokens.push_back(token.context);
    serialized_tokens.push_back(token.value);
  }
  std::vector<int64_t> context_map(codes.context_map.begin(), codes.context_map.end());
  std::vector<int64_t> uint_configs;
  for (const auto& config : codes.uint_config) {
    uint_configs.insert(uint_configs.end(), {
        config.split_exponent, config.split_token, config.msb_in_token,
        config.lsb_in_token});
  }
  std::vector<int64_t> table_frequencies;
  std::vector<int64_t> table_reverse_maps;
  std::vector<int64_t> table_lengths;
  for (const auto& table : codes.encoding_info) {
    table_lengths.push_back(table.size());
    for (const auto& symbol : table) {
      table_frequencies.push_back(symbol.freq_);
      for (uint16_t value : symbol.reverse_map_) table_reverse_maps.push_back(value);
    }
  }
  std::vector<int64_t> serialized_bytes(writer.GetSpan().begin(),
                                        writer.GetSpan().end());
  SemanticDumpWriter dump;
  dump.Integers("entropy.tree_entropy.speed_tier", {speed_tier});
  dump.Integers("entropy.tree_entropy.decoding_tier", {decoding_tier});
  dump.Integers("entropy.tree_entropy.extra_dc_precision", {extra_dc_precision});
  dump.Integers("entropy.tree_entropy.context_count", {jxl::kNumTreeContexts});
  dump.Integers("entropy.tree_entropy.clustering", {static_cast<int>(params.clustering)});
  dump.Integers("entropy.tree_entropy.ans_strategy",
                {static_cast<int>(params.ans_histogram_strategy)});
  dump.Integers("entropy.tree_entropy.lz77_method", {static_cast<int>(params.lz77_method)});
  dump.Integers("entropy.tree_entropy.uint_method", {static_cast<int>(params.uint_method)});
  dump.Integers("entropy.tree_entropy.use_prefix_code", {codes.use_prefix_code});
  dump.Integers("entropy.tree_entropy.log_alpha_size",
                {static_cast<int64_t>(codes.log_alpha_size)});
  dump.Integers("entropy.tree_entropy.input_token_count", {token_count});
  dump.Integers("entropy.tree_entropy.tokens", serialized_tokens);
  dump.Integers("entropy.tree_entropy.context_map", context_map);
  dump.Integers("entropy.tree_entropy.uint_configs", uint_configs);
  dump.Integers("entropy.tree_entropy.table_lengths", table_lengths);
  dump.Integers("entropy.tree_entropy.table_frequencies", table_frequencies);
  dump.Integers("entropy.tree_entropy.table_reverse_maps", table_reverse_maps);
  dump.Integers("entropy.tree_entropy.cost", {static_cast<int64_t>(cost)});
  dump.Integers("entropy.tree_entropy.bit_count",
                {static_cast<int64_t>(writer.BitsWritten())});
  dump.Integers("entropy.tree_entropy.bytes", serialized_bytes);
  dump.Write(stdout);
  return 0;
}

int RunACTokens(const std::vector<std::string>& args) {
  if (args.size() < 4) return 2;
  int width = 0;
  int height = 0;
  int num_contexts = 0;
  if (!ParseInt(args[0], &width) || !ParseInt(args[1], &height) ||
      !ParseInt(args[2], &num_contexts) || width <= 0 || height <= 0 ||
      width > 16 || height > 16 || width * height > 64 ||
      (num_contexts != 4 && num_contexts != 15)) return 2;
  const size_t blocks = static_cast<size_t>(width) * height;
  constexpr size_t kMapSize = 3 * jxl::kNumOrders;
  constexpr size_t kOrderSize = 64;
  const size_t expected = 3 + kMapSize + kOrderSize + blocks * 2 +
                          blocks * kOrderSize * 3;
  if (args.size() != expected) return 2;
  size_t cursor = 3;
  std::array<uint8_t, kMapSize> context_map{};
  for (auto& value : context_map) {
    int parsed = 0;
    if (!ParseInt(args[cursor++], &parsed) || parsed < 0 ||
        parsed >= num_contexts) return 2;
    value = static_cast<uint8_t>(parsed);
  }
  std::array<jxl::coeff_order_t, kOrderSize> order{};
  std::array<bool, kOrderSize> seen{};
  for (auto& value : order) {
    int parsed = 0;
    if (!ParseInt(args[cursor++], &parsed) || parsed < 0 || parsed >= 64 ||
        seen[parsed]) return 2;
    seen[parsed] = true;
    value = static_cast<jxl::coeff_order_t>(parsed);
  }
  std::vector<int> qdc(blocks);
  std::vector<int> qf(blocks);
  for (size_t i = 0; i < blocks; ++i) {
    if (!ParseInt(args[cursor++], &qdc[i]) || qdc[i] < 0 || qdc[i] > 255)
      return 2;
  }
  for (size_t i = 0; i < blocks; ++i) {
    if (!ParseInt(args[cursor++], &qf[i]) || qf[i] < 0) return 2;
  }
  std::array<std::vector<int32_t>, 3> coefficients;
  for (auto& channel : coefficients) {
    channel.resize(blocks * 64);
    for (auto& value : channel) {
      if (!ParseInt(args[cursor++], &value)) return 2;
    }
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  auto strategy_or = jxl::AcStrategyImage::Create(&manager, width, height);
  auto qdc_or = jxl::ImageB::Create(&manager, width, height);
  auto qf_or = jxl::ImageI::Create(&manager, width, height);
  auto scratch_or = jxl::Image3I::Create(&manager, width, height);
  if (!strategy_or.ok() || !qdc_or.ok() || !qf_or.ok() || !scratch_or.ok())
    return 1;
  auto strategy = std::move(strategy_or).value_();
  auto qdc_image = std::move(qdc_or).value_();
  auto qf_image = std::move(qf_or).value_();
  auto scratch = std::move(scratch_or).value_();
  strategy.FillDCT8();
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const size_t index = static_cast<size_t>(y) * width + x;
      qdc_image.Row(y)[x] = static_cast<uint8_t>(qdc[index]);
      qf_image.Row(y)[x] = qf[index];
    }
  }
  std::vector<jxl::coeff_order_t> orders(jxl::kCoeffOrderMaxSize);
  for (size_t channel = 0; channel < 3; ++channel) {
    std::copy(order.begin(), order.end(),
              orders.begin() + channel * kOrderSize);
  }
  jxl::BlockCtxMap block_map;
  block_map.ctx_map.assign(context_map.begin(), context_map.end());
  block_map.num_ctxs = num_contexts;
  block_map.num_dc_ctxs = 1;
  jxl::Rect rect(0, 0, width, height);
  jxl::YCbCrChromaSubsampling subsampling;
  const int32_t* rows[3] = {coefficients[0].data(), coefficients[1].data(),
                            coefficients[2].data()};
  std::vector<jxl::Token> tokens;
  if (!jxl::TokenizeCoefficients(orders.data(), rect, rows, strategy,
                                 subsampling, &scratch, &tokens, qdc_image,
                                 qf_image, block_map)) return 1;
  std::vector<int64_t> contexts;
  std::vector<int64_t> values;
  for (const auto& token : tokens) {
    contexts.push_back(token.context);
    values.push_back(token.value);
  }
  SemanticDumpWriter dump;
  dump.Integers("entropy.ac_tokens.context_count", {num_contexts});
  dump.Integers("entropy.ac_tokens.contexts", contexts);
  dump.Integers("entropy.ac_tokens.token_count",
                {static_cast<int64_t>(tokens.size())});
  dump.Integers("entropy.ac_tokens.values", values);
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
  if (args[0] == "tree") {
    return RunTree(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "modular") {
    return RunModular(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "ac-metadata") {
    return RunACMetadata(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "tree-entropy") {
    return RunTreeEntropy(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  if (args[0] == "ac-tokens") {
    return RunACTokens(std::vector<std::string>(args.begin() + 1, args.end()));
  }
  return 2;
}

const RegisterSubcommand kRegister({
    "entropy", "histogram|cluster|context-map|tree|modular|ac-metadata|tree-entropy ...",
    RunEntropy});

}  // namespace
}  // namespace harness
