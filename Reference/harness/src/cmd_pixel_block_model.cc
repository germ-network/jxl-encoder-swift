#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "lib/jxl/ac_context.h"
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/common.h"
#include "lib/jxl/enc_params.h"
#include "lib/jxl/image.h"
#include "lib/jxl/memory_manager_internal.h"
#include "registry.h"

namespace jxl {
void FindBestBlockEntropyModel(const CompressParams &, const ImageI &,
                               const AcStrategyImage &, BlockCtxMap *);
}

namespace harness {
namespace {

int RunPixelBlockModel(const std::vector<std::string> &args) {
  if (args.size() != 3)
    return 2;
  std::ifstream input(args[0]);
  std::vector<int> counts(256);
  size_t total = 0;
  for (int &count : counts) {
    if (!(input >> count) || count < 0)
      return 2;
    total += static_cast<size_t>(count);
  }
  std::string extra;
  if (input >> extra || total == 0 || total > 1000000)
    return 2;

  JxlMemoryManager memory_manager;
  if (!jxl::MemoryManagerInit(&memory_manager, nullptr))
    return 1;
  auto rqf_result = jxl::ImageI::Create(&memory_manager, total, 1);
  if (!rqf_result.ok())
    return 1;
  auto strategy_result =
      jxl::AcStrategyImage::Create(&memory_manager, total, 1);
  if (!strategy_result.ok())
    return 1;
  auto rqf = std::move(rqf_result).value_();
  auto strategy = std::move(strategy_result).value_();
  strategy.FillDCT8();
  size_t x = 0;
  for (size_t quant = 0; quant < counts.size(); ++quant) {
    for (int i = 0; i < counts[quant]; ++i)
      rqf.Row(0)[x++] = quant + 1;
  }

  jxl::CompressParams params;
  params.speed_tier = jxl::SpeedTier::kCheetah;
  params.decoding_speed_tier = 0;
  params.butteraugli_distance = std::stof(args[1]);
  jxl::BlockCtxMap model;
  jxl::FindBestBlockEntropyModel(params, rqf, strategy, &model);
  std::ofstream output(args[2]);
  output << "total " << total << "\nqf_thresholds";
  for (uint32_t value : model.qf_thresholds)
    output << ' ' << value;
  output << "\nnum_contexts " << model.num_ctxs << "\ncontext_map";
  for (uint8_t value : model.ctx_map)
    output << ' ' << static_cast<int>(value);
  const uint32_t threshold =
      model.qf_thresholds.empty() ? 0 : model.qf_thresholds[0];
  output << "\nconsumer_raw_qf " << threshold << ' ' << threshold + 1
         << "\nconsumer_categories";
  for (size_t channel = 0; channel < 3; ++channel) {
    output << ' ' << model.Context(0, threshold, 0, channel);
    output << ' ' << model.Context(0, threshold + 1, 0, channel);
  }
  output << '\n';
  return output ? 0 : 1;
}

const RegisterSubcommand kRegister({"pixel-block-model",
                                    "<256-counts.txt> <distance>",
                                    RunPixelBlockModel});

} // namespace
} // namespace harness
