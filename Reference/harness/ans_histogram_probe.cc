#include <algorithm>
#include <cstdint>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

#include <jxl/memory_manager.h>

#include "semantic_dump.h"
#include "lib/jxl/enc_ans.cc"
#include "lib/jxl/enc_ans_params.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/memory_manager_internal.h"

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  jxl::HistogramParams::ANSHistogramStrategy strategy;
  const std::string strategy_name(argv[1]);
  if (strategy_name == "fast") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kFast;
  } else if (strategy_name == "approximate") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kApproximate;
  } else if (strategy_name == "precise") {
    strategy = jxl::HistogramParams::ANSHistogramStrategy::kPrecise;
  } else {
    return 2;
  }

  if (argc - 2 > 256) return 2;
  jxl::Histogram histogram(argc - 2);
  int64_t total_count = 0;
  for (int i = 2; i < argc; ++i) {
    try {
      const long long value = std::stoll(argv[i]);
      if (value < 0 || value > std::numeric_limits<int32_t>::max()) return 2;
      if (value > std::numeric_limits<int32_t>::max() - total_count) return 2;
      total_count += value;
      histogram.counts[i - 2] = value;
      histogram.total_count += value;
    } catch (...) {
      return 2;
    }
  }

  auto selected = jxl::ANSEncodingHistogram::ComputeBest(histogram, strategy);
  if (!selected.ok()) return 1;
  auto result = std::move(selected).value_();
  jxl::SizeWriter size_writer;
  if (!result.Encode(&size_writer)) return 1;

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::BitWriter writer(&manager);
  const jxl::Status encoded = writer.WithMaxBits(
      256 + histogram.alphabet_size() * 24, jxl::LayerType::Header, nullptr,
      [&]() -> jxl::Status { return result.Encode(&writer); });
  if (!encoded) return 1;
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
    const size_t method = read_bits(log) | (size_t{1} << log);
    serialized_method = 2;
    serialized_shift = static_cast<int>(method - 1);
  }

  std::vector<int64_t> normalized;
  for (size_t i = 0; i < histogram.alphabet_size(); ++i) {
    normalized.push_back(result.Counts()[i]);
  }

  std::vector<uint32_t> fixed_log2(ANS_TAB_SIZE + 1);
  for (size_t i = 1; i < fixed_log2.size(); ++i) {
    fixed_log2[i] = std::round(std::ldexp(
        std::log2(static_cast<double>(i)) / ANS_LOG_TAB_SIZE, 31));
  }
  float source_data_bits = 0;
  const size_t nonzero_count = std::count_if(
      histogram.counts.begin(), histogram.counts.end(), [](int32_t value) {
        return value > 0;
      });
  if (nonzero_count > 1 && !normalized.empty()) {
    int64_t sum = 0;
    for (size_t i = 0; i < histogram.alphabet_size(); ++i) {
      sum += static_cast<int64_t>(histogram.counts[i]) * fixed_log2[result.Counts()[i]];
    }
    if (serialized_method == 0) {
      const int64_t flat_bits =
          static_cast<int64_t>(fixed_log2[histogram.alphabet_size()]) * ANS_LOG_TAB_SIZE;
	  source_data_bits = std::ldexpf(
	      static_cast<float>(histogram.total_count * flat_bits), -31);
    } else {
      source_data_bits =
          (histogram.total_count - std::ldexp(static_cast<float>(sum), -31)) *
          ANS_LOG_TAB_SIZE;
    }
  }
  std::vector<int64_t> serialized(bytes.begin(), bytes.end());
  harness::SemanticDumpWriter dump;
  dump.Integers("entropy.ans_cost.normalized", normalized);
  dump.Integers("entropy.ans_cost.serialized_method", {serialized_method});
  dump.Integers("entropy.ans_cost.serialized_shift", {serialized_shift});
  dump.Integers("entropy.ans_cost.header_bits", {static_cast<int64_t>(bit_count)});
  dump.Integers("entropy.ans_cost.bytes", serialized);
  dump.Floats("entropy.ans_cost.total_cost", {result.Cost()});
  dump.Floats("entropy.ans_cost.source_data_bits", {source_data_bits});
  dump.Write(stdout);
  return 0;
}
