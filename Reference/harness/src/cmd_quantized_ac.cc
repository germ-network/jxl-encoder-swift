#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
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

uint32_t FloatBits(float value) {
  uint32_t bits;
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

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

int RunE4QuantizedAC(const std::vector<std::string>& args) {
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
    std::array<float, 4> thresholds = channel == 1
        ? std::array<float, 4>{0.56f, 0.62f, 0.62f, 0.62f}
        : std::array<float, 4>{0.58f, 0.62f, 0.62f, 0.62f};
    jxl::HWY_NAMESPACE::QuantizeBlockAC(
        quantizer, false, channel, matrix_multipliers[channel],
        jxl::AcStrategyType::DCT, 1, 1, thresholds.data(), coefficients.data(),
        &quant, output.data());
    std::vector<int64_t> values(output.begin(), output.end());
    dump.Integers("quantized_ac.c" + std::to_string(channel), values);
  }
  const std::array<size_t, 4> indexes = {1, 4, 32, 36};
  std::vector<int64_t> boundary_channels, boundary_indexes, boundary_targets;
  std::vector<int64_t> boundary_inputs, boundary_scaled, boundary_outputs;
  for (size_t channel = 0; channel < 3; ++channel) {
    const std::array<float, 4> thresholds = channel == 1
        ? std::array<float, 4>{0.56f, 0.62f, 0.62f, 0.62f}
        : std::array<float, 4>{0.58f, 0.62f, 0.62f, 0.62f};
    const float multiplier = matrix_multipliers[channel];
    const float quant_scale = quantizer.Scale() * quant * multiplier;
    const float* inverse = quantizer.InvDequantMatrix(
        jxl::AcStrategyType::DCT, channel);
    for (size_t quadrant = 0; quadrant < indexes.size(); ++quadrant) {
      const size_t index = indexes[quadrant];
      const float threshold = thresholds[quadrant];
      for (float sign : {-1.0f, 1.0f}) {
        for (float target : {std::nextafter(threshold, -INFINITY), threshold,
                             std::nextafter(threshold, INFINITY)}) {
          float low = target / (inverse[index] * quant_scale);
          float high = low;
          float input = 0.0f;
          float scaled = 0.0f;
          bool found = false;
          for (size_t attempt = 0; attempt < 4096 && !found; ++attempt) {
            for (float candidate : {low, high}) {
              scaled = std::abs((inverse[index] * quant_scale) * candidate);
              if (FloatBits(scaled) == FloatBits(target)) {
                input = candidate;
                found = true;
                break;
              }
            }
            low = std::nextafter(low, 0.0f);
            high = std::nextafter(high, INFINITY);
          }
          if (!found) return 1;
          std::array<float, 64> boundary_coefficients{};
          boundary_coefficients[index] = sign * input;
          std::array<int32_t, 64> boundary_output{};
          auto block_thresholds = thresholds;
          jxl::HWY_NAMESPACE::QuantizeBlockAC(
              quantizer, false, channel, multiplier, jxl::AcStrategyType::DCT,
              1, 1, block_thresholds.data(), boundary_coefficients.data(),
              &quant, boundary_output.data());
          boundary_channels.push_back(channel);
          boundary_indexes.push_back(index);
          boundary_targets.push_back(FloatBits(target));
          boundary_inputs.push_back(FloatBits(sign * input));
          boundary_scaled.push_back(FloatBits(scaled));
          boundary_outputs.push_back(boundary_output[index]);
        }
      }
    }
  }
  dump.Integers("e4_boundary.channel", boundary_channels);
  dump.Integers("e4_boundary.index", boundary_indexes);
  dump.Integers("e4_boundary.target_bits", boundary_targets);
  dump.Integers("e4_boundary.input_bits", boundary_inputs);
  dump.Integers("e4_boundary.scaled_bits", boundary_scaled);
  dump.Integers("e4_boundary.output", boundary_outputs);
  FILE* file = std::fopen(args[0].c_str(), "w");
  if (file == nullptr) return 1;
  dump.Write(file);
  return std::fclose(file) == 0 ? 0 : 1;
}

int RunE4EdgeQuantizedAC(const std::vector<std::string>& args) {
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
      std::array<float, 4> thresholds = channel == 1
          ? std::array<float, 4>{0.56f, 0.62f, 0.62f, 0.62f}
          : std::array<float, 4>{0.58f, 0.62f, 0.62f, 0.62f};
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
const RegisterSubcommand kRegisterE4(
    {"e4-quantized-ac", "<out.sem>", RunE4QuantizedAC});
const RegisterSubcommand kRegisterE4Edge(
    {"e4-quantized-edge-ac", "<edge-dct.dump> <out.sem>",
     RunE4EdgeQuantizedAC});

}  // namespace
}  // namespace harness
