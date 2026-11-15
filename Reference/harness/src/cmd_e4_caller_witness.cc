#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <jxl/cms.h>
#include "decoded_frame.h"
#include "lib/jxl/enc_cache.h"
#include "lib/jxl/dec_transforms_testonly.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_group.h"
#include "lib/jxl/enc_heuristics.h"
#include "lib/jxl/enc_modular.h"
#include "lib/jxl/enc_transforms.h"
#include "lib/jxl/memory_manager_internal.h"
#include "registry.h"
#include "semantic_dump.h"
#include "stage_dump.h"

namespace harness {
namespace {

constexpr size_t kWidth = 8;
constexpr size_t kProbeCount = 10;
constexpr size_t kHeight = 8 * kProbeCount;
constexpr std::array<size_t, kProbeCount> kChannels = {
    1, 1, 1, 1, 0, 0, 0, 2, 2, 2};
constexpr std::array<size_t, kProbeCount> kIndexes = {
    1, 4, 32, 36, 4, 32, 36, 4, 32, 36};
constexpr std::array<float, kProbeCount> kTargets = {
    0.57f, 0.63f, 0.63f, 0.63f, 0.63f,
    0.63f, 0.63f, 0.63f, 0.63f, 0.63f};

uint32_t FloatBits(float value) {
  uint32_t bits;
  std::memcpy(&bits, &value, sizeof(bits));
  return bits;
}

void SetProbeInputs(jxl::Image3F* opsin,
                    const jxl::PassesEncoderState& state,
                    const jxl::FrameHeader& frame_header) {
  for (size_t probe = 0; probe < kProbeCount; ++probe) {
    const size_t channel = kChannels[probe];
    const size_t index = kIndexes[probe];
    const float multiplier = channel == 0
        ? std::pow(1.25f, frame_header.x_qm_scale - 2.0f)
        : channel == 2
            ? std::pow(1.25f, frame_header.b_qm_scale - 2.0f)
            : 1.0f;
    const float qac = state.shared.quantizer.Scale() *
        state.shared.raw_quant_field.Row(probe)[0] * multiplier;
    const float* inverse = state.shared.quantizer.InvDequantMatrix(
        jxl::AcStrategyType::DCT, channel);
    std::array<float, 64> coefficients{};
    coefficients[index] = kTargets[probe] / (inverse[index] * qac);
    std::array<float, 4096> scratch{};
    jxl::TransformToPixels(jxl::AcStrategyType::DCT, coefficients.data(),
        opsin->PlaneRow(channel, probe * 8), opsin->PixelsPerRow(),
        scratch.data());
  }
}

jxl::Status RunE4CallerWitness(const std::vector<std::string>& args) {
  if (args.size() != 3) return false;
  std::ifstream codestream(args[0], std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(codestream)), {});
  DecodedFrame decoded;
  if (!DecodeFirstFrame(bytes, &decoded) || decoded.metadata.size.xsize() != kWidth ||
      decoded.metadata.size.ysize() != kHeight) return false;

  JxlMemoryManager memory_manager;
  JXL_RETURN_IF_ERROR(jxl::MemoryManagerInit(&memory_manager, nullptr));
  const jxl::FrameHeader& frame_header = decoded.header;
  if (frame_header.encoding != jxl::FrameEncoding::kVarDCT ||
      frame_header.upsampling != 1 ||
      (frame_header.flags & jxl::FrameHeader::kUseDcFrame) != 0 ||
      frame_header.x_qm_scale != 3 || frame_header.b_qm_scale != 2) return false;

  jxl::PassesEncoderState state(&memory_manager);
  state.cparams.speed_tier = jxl::SpeedTier::kCheetah;
  state.cparams.butteraugli_distance = 1.0f;
  JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&state.cparams));
  state.streaming_mode = false;
  state.initialize_global_state = true;
  state.dc_group_index = 0;
  JXL_RETURN_IF_ERROR(
      jxl::InitializePassesSharedState(frame_header, &state.shared, true));
  if (state.shared.frame_dim.num_groups != 1 ||
      state.shared.frame_dim.xsize_blocks != 1 ||
      state.shared.frame_dim.ysize_blocks != kProbeCount) return false;
  JXL_ASSIGN_OR_RETURN(
      auto modular,
      jxl::ModularFrameEncoder::Create(
          &memory_manager, frame_header, state.cparams, false));
  JXL_ASSIGN_OR_RETURN(
      auto opsin,
      jxl::Image3F::Create(&memory_manager, kWidth, kHeight));
  JXL_RETURN_IF_ERROR(opsin.ShrinkTo(kWidth, kHeight));
  for (size_t c = 0; c < 3; ++c) {
    for (size_t y = 0; y < kHeight; ++y) {
      std::fill(opsin.PlaneRow(c, y), opsin.PlaneRow(c, y) + kWidth, 0.0f);
    }
  }

  const jxl::Rect rect(0, 0, kWidth, kHeight);
  JXL_RETURN_IF_ERROR(jxl::LossyFrameHeuristics(
      frame_header, &state, modular.get(), nullptr, &opsin, rect,
      *JxlGetDefaultCms(), nullptr, nullptr));
  SetProbeInputs(&opsin, state, frame_header);
  JXL_RETURN_IF_ERROR(jxl::InitializePassesEncoder(
      frame_header, opsin, rect, *JxlGetDefaultCms(), nullptr, &state,
      modular.get(), nullptr));
  state.initialize_global_state = false;
  SetProbeInputs(&opsin, state, frame_header);
  JXL_RETURN_IF_ERROR(jxl::InitializePassesEncoder(
      frame_header, opsin, rect, *JxlGetDefaultCms(), nullptr, &state,
      modular.get(), nullptr));

  std::array<std::vector<int64_t>, 3> outputs;
  for (size_t c = 0; c < 3; ++c) {
    const size_t count = kProbeCount * 64;
    const int32_t* source = state.coeffs[0]->PlaneRow(c, 0, 0).ptr32;
    outputs[c].assign(source, source + count);
  }

  std::vector<int64_t> scaled_bits;
  std::vector<int64_t> channel_values;
  std::vector<int64_t> indexes;
  std::vector<int64_t> target_bits;
  std::vector<int64_t> quant_values;
  scaled_bits.reserve(kProbeCount);
  std::vector<float> measured_scaled;
  measured_scaled.reserve(kProbeCount);
  for (size_t probe = 0; probe < kProbeCount; ++probe) {
    const size_t channel = kChannels[probe];
    const size_t index = kIndexes[probe];
    std::array<float, 64> coefficients{};
    std::array<float, 4096> scratch{};
    jxl::TransformFromPixels(jxl::AcStrategyType::DCT,
        opsin.ConstPlaneRow(channel, probe * 8), opsin.PixelsPerRow(),
        coefficients.data(), scratch.data());
    const float multiplier = channel == 0 ? state.x_qm_multiplier
        : channel == 2 ? state.b_qm_multiplier : 1.0f;
    const float qac = state.shared.quantizer.Scale() *
        state.shared.raw_quant_field.Row(probe)[0] * multiplier;
    measured_scaled.push_back(std::abs(
        state.shared.quantizer.InvDequantMatrix(
            jxl::AcStrategyType::DCT, channel)[index] * qac *
        coefficients[index]));
  }
  for (size_t probe = 0; probe < kProbeCount; ++probe) {
    const size_t channel = kChannels[probe];
    const size_t index = kIndexes[probe];
    const float scaled = measured_scaled[probe];
    scaled_bits.push_back(static_cast<int64_t>(FloatBits(scaled)));
    channel_values.push_back(static_cast<int64_t>(channel));
    indexes.push_back(static_cast<int64_t>(index));
    target_bits.push_back(static_cast<int64_t>(FloatBits(kTargets[probe])));
    quant_values.push_back(state.shared.raw_quant_field.Row(probe)[0]);
    if (probe == 0) {
      if (!(scaled > 0.56f && scaled < 0.58f)) {
        return false;
      }
    } else if (!(scaled > 0.62f && scaled < 0.635f)) {
      return false;
    }
  }

  SemanticDumpWriter dump;
  dump.Integers("e4_caller.channel", channel_values);
  dump.Integers("e4_caller.index", indexes);
  dump.Integers("e4_caller.target_bits", target_bits);
  dump.Integers("e4_caller.scaled_bits", scaled_bits);
  dump.Integers("e4_caller.quant", quant_values);
  for (size_t c = 0; c < 3; ++c) {
    dump.Integers("e4_caller.c" + std::to_string(c), outputs[c]);
  }
  FILE* file = std::fopen(args[1].c_str(), "w");
  if (file == nullptr) return false;
  dump.Write(file);
  const bool written = std::fclose(file) == 0;
  return written && WriteStageDump(args[2], opsin);
}

int Run(const std::vector<std::string>& args) {
  const jxl::Status status = RunE4CallerWitness(args);
  return status ? 0 : 1;
}

const RegisterSubcommand kRegister(
    {"e4-caller-witness", "<frame.jxl> <out.sem> <opsin.dump>", Run});

}  // namespace
}  // namespace harness
