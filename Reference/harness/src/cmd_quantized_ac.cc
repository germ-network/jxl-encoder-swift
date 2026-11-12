#include <array>
#include <cstdio>
#include <vector>

#include "hwy/highway.h"
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/quantizer.h"
#include "lib/jxl/quant_weights.h"
#include "registry.h"
#include "semantic_dump.h"
#include "stage_dump.h"

namespace jxl {
namespace HWY_NAMESPACE {
void QuantizeBlockAC(const Quantizer&, bool, size_t, float, AcStrategyType,
                     size_t, size_t, float*, const float*, const int32_t*,
                     int32_t*);
}
}  // namespace jxl

namespace harness {
namespace {

int RunQuantizedAC(const std::vector<std::string>& args) {
  if (args.size() != 1 || HWY_TARGET != HWY_NEON) return 2;
  JxlMemoryManager memory_manager;
  if (!jxl::MemoryManagerInit(&memory_manager, nullptr)) return 1;
  jxl::DequantMatrices matrices;
  if (!matrices.EnsureComputed(&memory_manager, 1)) return 1;
  jxl::Quantizer quantizer(matrices, 10, 7345);
  if (quantizer.Scale() != 0.1120758056640625f) return 1;
  const int32_t quant = 5;
  const std::array<float, 3> matrix_multipliers = {1.25f, 1.0f, 1.0f};
  std::array<float, 64> coefficients{};
  for (size_t i = 0; i < coefficients.size(); ++i) {
    coefficients[i] = static_cast<float>(static_cast<int>((i * 37) % 101) - 50) * 0.03125f;
  }

  SemanticDumpWriter dump;
  dump.Integers("quantized_ac.neon_target", {1});
  for (size_t channel = 0; channel < 3; ++channel) {
    std::array<int32_t, 64> output{};
    std::array<float, 4> thresholds = {0.58f, 0.635f, 0.66f, 0.7f};
    if (channel == 0) {
      for (size_t i = 1; i < thresholds.size(); ++i) thresholds[i] += 0.08f;
    } else if (channel == 2) {
      for (size_t i = 1; i < thresholds.size(); ++i) thresholds[i] = 0.75f;
    }
    jxl::HWY_NAMESPACE::QuantizeBlockAC(
        quantizer, false, channel, matrix_multipliers[channel],
        jxl::AcStrategyType::DCT, 1, 1, thresholds.data(), coefficients.data(),
        &quant, output.data());
    std::vector<int64_t> values(output.begin(), output.end());
    dump.Integers("quantized_ac.c" + std::to_string(channel), values);
  }
  FILE* file = std::fopen(args[0].c_str(), "w");
  if (file == nullptr) return 1;
  dump.Write(file);
  return std::fclose(file) == 0 ? 0 : 1;
}

int RunEdgeQuantizedAC(const std::vector<std::string>& args) {
  if (args.size() != 2 || HWY_TARGET != HWY_NEON) return 2;
  jxl::Image3F coefficients;
  if (!ReadStageDump(args[0], &coefficients) || coefficients.xsize() % 64 != 0 ||
      coefficients.ysize() != 1) return 1;
  JxlMemoryManager memory_manager;
  if (!jxl::MemoryManagerInit(&memory_manager, nullptr)) return 1;
  jxl::DequantMatrices matrices;
  if (!matrices.EnsureComputed(&memory_manager, 1)) return 1;
  jxl::Quantizer quantizer(matrices, 10, 7345);
  if (quantizer.Scale() != 0.1120758056640625f) return 1;
  const int32_t quant = 5;
  const std::array<float, 3> matrix_multipliers = {1.25f, 1.0f, 1.0f};
  const size_t block_count = coefficients.xsize() / 64;
  SemanticDumpWriter dump;
  dump.Integers("quantized_edge.neon_target", {1});
  dump.Integers("quantized_edge.block_count", {static_cast<int64_t>(block_count)});
  for (size_t channel = 0; channel < 3; ++channel) {
    std::vector<int64_t> values(block_count * 64);
    for (size_t block = 0; block < block_count; ++block) {
      std::array<int32_t, 64> output{};
      std::array<float, 4> thresholds = {0.58f, 0.635f, 0.66f, 0.7f};
      if (channel == 0) {
        for (size_t i = 1; i < thresholds.size(); ++i) thresholds[i] += 0.08f;
      } else if (channel == 2) {
        for (size_t i = 1; i < thresholds.size(); ++i) thresholds[i] = 0.75f;
      }
      jxl::HWY_NAMESPACE::QuantizeBlockAC(
          quantizer, false, channel, matrix_multipliers[channel],
          jxl::AcStrategyType::DCT, 1, 1, thresholds.data(),
          coefficients.PlaneRow(channel, 0) + block * 64, &quant, output.data());
      for (size_t i = 0; i < 64; ++i) values[block * 64 + i] = output[i];
    }
    dump.Integers("quantized_edge.c" + std::to_string(channel), values);
  }
  FILE* file = std::fopen(args[1].c_str(), "w");
  if (file == nullptr) return 1;
  dump.Write(file);
  return std::fclose(file) == 0 ? 0 : 1;
}

const RegisterSubcommand kRegister(
    {"quantized-ac", "<out.sem>", RunQuantizedAC});
const RegisterSubcommand kRegisterEdge(
    {"quantized-edge-ac", "<edge-dct.dump> <out.sem>", RunEdgeQuantizedAC});

}  // namespace
}  // namespace harness
