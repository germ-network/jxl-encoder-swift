#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>

#include "hwy/highway.h"
#include "lib/jxl/quantizer.h"
#include "lib/jxl/quantizer-inl.h"
#include "registry.h"
#include "semantic_dump.h"

namespace harness {
namespace {

int RunQuantBias(const std::vector<std::string>& args) {
  if (args.size() != 1 || HWY_TARGET != HWY_NEON) return 2;
  constexpr std::array<int32_t, 13> inputs = {
      0, 1, -1, 2, -2, 3, -3, 20, -20, 255, -255, 1024, -1024};
  HWY_CAPPED(int32_t, 4) di;
  const hwy::HWY_NAMESPACE::Rebind<float, decltype(di)> df;
  if (hwy::HWY_NAMESPACE::Lanes(di) != 4) return 1;

  SemanticDumpWriter dump;
  dump.Integers("quant_bias.neon_target", {1});
  for (size_t channel = 0; channel < 3; ++channel) {
    std::vector<int64_t> bits;
    for (size_t offset = 0; offset < inputs.size(); offset += 4) {
      HWY_ALIGN int32_t lanes[4] = {0, 0, 0, 0};
      HWY_ALIGN float output[4] = {};
      const size_t count = std::min<size_t>(4, inputs.size() - offset);
      for (size_t i = 0; i < count; ++i) lanes[i] = inputs[offset + i];
      hwy::HWY_NAMESPACE::Store(
          jxl::HWY_NAMESPACE::AdjustQuantBias(
              di, channel, hwy::HWY_NAMESPACE::Load(di, lanes),
              jxl::kDefaultQuantBias),
          df, output);
      for (size_t i = 0; i < count; ++i) {
        bits.push_back(static_cast<int64_t>(
            hwy::BitCastScalar<uint32_t>(output[i])));
      }
    }
    dump.Integers("quant_bias.c" + std::to_string(channel), bits);
  }
  FILE* file = std::fopen(args[0].c_str(), "w");
  if (file == nullptr) return 1;
  dump.Write(file);
  return std::fclose(file) == 0 ? 0 : 1;
}

const RegisterSubcommand kRegister({"quant-bias", "<out.sem>", RunQuantBias});

}  // namespace
}  // namespace harness
