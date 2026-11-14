#include "registry.h"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <sstream>
#include <string_view>
#include <vector>

#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/coeff_order.h"
#include "lib/jxl/dct_util.h"
#include "lib/jxl/enc_coeff_order.h"
#include "lib/jxl/frame_dimensions.h"
#include "lib/jxl/memory_manager_internal.h"

namespace harness {
namespace {

bool ParseSize(std::string_view text, size_t *value) {
  uint64_t parsed = 0;
  const auto result =
      std::from_chars(text.data(), text.data() + text.size(), parsed);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size())
    return false;
  *value = static_cast<size_t>(parsed);
  return *value == parsed;
}

class Coefficients final : public jxl::ACImage {
public:
  Coefficients(const std::vector<size_t> &zero_positions,
               size_t exception_group, size_t exception_block,
               size_t exception_position)
      : other_(RowSize, 1), exception_group_(exception_group) {
    for (size_t block = 0; block < 32 * 32; ++block) {
      for (size_t position : zero_positions) {
        other_[block * 64 + position] = 0;
      }
    }
    exception_ = other_;
    exception_[exception_block * 64 + exception_position] = 1;
  }
  Coefficients(size_t blocks, const std::vector<uint32_t> &counts)
      : count_rows_(3, std::vector<int16_t>(RowSize)), counts_(counts),
        blocks_(blocks) {}

  jxl::ACType Type() const override { return jxl::ACType::k16; }
  jxl::ACPtr PlaneRow(size_t, size_t y, size_t x) override {
    if (!count_rows_.empty()) {
      MakeCountRow(0, y);
      return jxl::ACPtr(count_rows_[0].data() + x);
    }
    return jxl::ACPtr((y == exception_group_ ? exception_ : other_).data() + x);
  }
  jxl::ConstACPtr PlaneRow(size_t c, size_t y, size_t x) const override {
    if (!count_rows_.empty()) {
      MakeCountRow(c, y);
      return jxl::ConstACPtr(count_rows_[c].data() + x);
    }
    return jxl::ConstACPtr(
        (y == exception_group_ ? exception_ : other_).data() + x);
  }
  size_t PixelsPerRow() const override { return RowSize; }
  void ZeroFill() override {}
  void ZeroFillPlane(size_t) override {}
  bool IsEmpty() const override { return false; }

private:
  void MakeCountRow(size_t channel, size_t group) const {
    auto &row = count_rows_[channel];
    std::fill(row.begin(), row.end(), 1);
    const size_t first_block = group * 32;
    for (size_t block = 0; block < 32 && first_block + block < blocks_;
         ++block) {
      for (size_t k = 0; k < 64; ++k) {
        if (channel == 0 && first_block + block < counts_[k]) {
          row[block * 64 + k] = 0;
        }
      }
    }
  }
  static constexpr size_t RowSize = 32 * 32 * jxl::kDCTBlockSize;
  std::vector<int16_t> other_;
  std::vector<int16_t> exception_;
  size_t exception_group_;
  mutable std::vector<std::vector<int16_t>> count_rows_;
  std::vector<uint32_t> counts_;
  size_t blocks_ = 0;
};

int Run(const std::vector<std::string> &args) {
  if (args.size() == 1 && args[0] == "natural") {
    std::vector<jxl::coeff_order_t> order(jxl::kDCTBlockSize);
    jxl::AcStrategy::FromRawStrategy(jxl::AcStrategyType::DCT)
        .ComputeNaturalCoeffOrder(order.data());
    SemanticDumpWriter dump;
    std::vector<int64_t> values(order.begin(), order.end());
    dump.Integers("entropy.coefficient_natural.order", values);
    dump.Write(stdout);
    return 0;
  }
  if (args.size() == 3 && args[0] == "counts") {
    size_t blocks = 0;
    if (!ParseSize(args[1], &blocks) || blocks == 0 || blocks > 8'500'000)
      return 2;
    std::vector<uint32_t> counts;
    std::stringstream stream(args[2]);
    std::string item;
    while (std::getline(stream, item, ',')) {
      size_t value = 0;
      if (!ParseSize(item, &value) || value > blocks)
        return 2;
      counts.push_back(static_cast<uint32_t>(value));
    }
    if (counts.size() != 64)
      return 2;
    JxlMemoryManager manager;
    if (!jxl::MemoryManagerInit(&manager, nullptr))
      return 1;
    auto strategy_or = jxl::AcStrategyImage::Create(&manager, blocks, 1);
    if (!strategy_or.ok())
      return 1;
    auto strategy = std::move(strategy_or).value_();
    strategy.FillDCT8();
    jxl::FrameDimensions dim;
    dim.Set(blocks * jxl::kBlockDim, jxl::kBlockDim, 1, 0, 0, false, 1);
    Coefficients image(blocks, counts);
    std::vector<jxl::coeff_order_t> order(jxl::kCoeffOrderMaxSize);
    uint32_t used_orders = 0;
    if (!jxl::ComputeCoeffOrder(jxl::SpeedTier::kWombat, image, strategy, dim,
                                used_orders, 0, 1, 1, order.data()))
      return 1;
    SemanticDumpWriter dump;
    dump.Integers("entropy.coefficient_order.counts",
                  std::vector<int64_t>(counts.begin(), counts.end()));
    dump.Integers("entropy.coefficient_order.reference_order",
                  std::vector<int64_t>(order.begin(), order.begin() + 64));
    dump.Write(stdout);
    return 0;
  }
  if (args.size() != 9 || args[0] != "sample")
    return 2;
  size_t width = 0;
  size_t height = 0;
  size_t speed = 0;
  size_t zero0 = 0;
  size_t zero1 = 0;
  size_t exception_group = 0;
  size_t exception_block = 0;
  size_t exception_position = 0;
  if (!ParseSize(args[1], &width) || !ParseSize(args[2], &height) ||
      !ParseSize(args[3], &speed) || !ParseSize(args[4], &zero0) ||
      !ParseSize(args[5], &zero1) || !ParseSize(args[6], &exception_group) ||
      !ParseSize(args[7], &exception_block) ||
      !ParseSize(args[8], &exception_position) || speed > 6 || zero0 >= 64 ||
      zero1 >= 64 || zero0 == zero1 || exception_block >= 1024 ||
      exception_position >= 64 || width == 0 || height == 0 ||
      width > 8'500'000 || height > 8'500'000 || width > 8'500'000 / height ||
      width > SIZE_MAX / height / jxl::kDCTBlockSize)
    return 2;

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr))
    return 1;
  auto strategy_or = jxl::AcStrategyImage::Create(&manager, width, height);
  if (!strategy_or.ok())
    return 1;
  auto strategy = std::move(strategy_or).value_();
  strategy.FillDCT8();
  jxl::FrameDimensions dim;
  dim.Set(width * jxl::kBlockDim, height * jxl::kBlockDim, 1, 0, 0, false, 1);
  if (exception_group >= dim.num_groups)
    return 2;
  Coefficients image({zero0, zero1}, exception_group, exception_block,
                     exception_position);
  std::vector<jxl::coeff_order_t> order(jxl::kCoeffOrderMaxSize);
  uint32_t used_orders = 0;
  if (!jxl::ComputeCoeffOrder(static_cast<jxl::SpeedTier>(speed), image,
                              strategy, dim, used_orders, 0, 1, 1,
                              order.data()))
    return 1;
  SemanticDumpWriter dump;
  dump.Integers("entropy.coefficient_sampling.blocks",
                {static_cast<int64_t>(width), static_cast<int64_t>(height)});
  dump.Integers("entropy.coefficient_sampling.group_count",
                {static_cast<int64_t>(dim.num_groups)});
  dump.Integers(
      "entropy.coefficient_sampling.order",
      std::vector<int64_t>(order.begin(), order.begin() + jxl::kDCTBlockSize));
  dump.Write(stdout);
  return 0;
}

} // namespace

static RegisterSubcommand
    register_coeff_order({"coefficient-order",
                          "natural | sample <width> <height> <speed> <zero0> "
                          "<zero1> <group> <slot> <exception>",
                          Run});

} // namespace harness
