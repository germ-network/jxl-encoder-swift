#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>

#include "decoded_frame.h"
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/compressed_dc.h"
#include "lib/jxl/enc_entropy_coder.h"
#include "lib/jxl/jpeg/enc_jpeg_data.h"
#include "lib/jxl/jpeg/enc_jpeg_data_reader.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/modular/transform/transform.h"
#include "registry.h"

namespace harness {
namespace {

std::vector<uint8_t> Read(const std::string& path) {
  std::ifstream file(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(file), {}};
}

jxl::Status Witness(const std::string& jpeg_path, const std::string& jxl_path,
                    SemanticDumpWriter* out) {
  const auto jpeg_bytes = Read(jpeg_path);
  const auto jxl_bytes = Read(jxl_path);
  if (jpeg_bytes.empty() || jxl_bytes.empty()) return false;

  jxl::jpeg::JPEGData jpeg;
  JXL_RETURN_IF_ERROR(jxl::jpeg::ReadJpeg(
      jpeg_bytes.data(), jpeg_bytes.size(), jxl::jpeg::JpegReadMode::kReadAll,
      &jpeg));
  DecodedFrame frame;
  if (!DecodeFirstFrame(jxl_bytes, &frame)) return false;
  if (jpeg.components.size() != 3 || frame.header.color_transform != jxl::ColorTransform::kYCbCr ||
      frame.header.encoding != jxl::FrameEncoding::kVarDCT ||
      frame.header.passes.num_passes != 1 || frame.state->used_acs != 1) {
    std::fprintf(stderr, "jpeg-witness: unsupported frame configuration\n");
    return false;
  }

  const auto dim = frame.header.ToFrameDimensions();
  if (jpeg.width != static_cast<int>(frame.header.default_xsize()) ||
      jpeg.height != static_cast<int>(frame.header.default_ysize())) {
    std::fprintf(stderr, "jpeg-witness: source/reference dimensions differ\n");
    return false;
  }
  jxl::YCbCrChromaSubsampling source_sampling;
  JXL_RETURN_IF_ERROR(
      jxl::jpeg::SetChromaSubsamplingFromJpegData(jpeg, &source_sampling));
  const auto cs = frame.header.chroma_subsampling;
  for (size_t c = 0; c < 3; ++c) {
    if (source_sampling.HShift(c) != cs.HShift(c) ||
        source_sampling.VShift(c) != cs.VShift(c)) {
      std::fprintf(stderr, "jpeg-witness: source/reference sampling differs\n");
      return false;
    }
  }

  const auto& shared = *frame.state->shared;
  const auto& block_map = shared.block_ctx_map;
  if (!block_map.dc_thresholds[0].empty() ||
      !block_map.dc_thresholds[2].empty() ||
      !block_map.qf_thresholds.empty() || block_map.num_dc_ctxs < 2 ||
      block_map.ctx_map.size() != 3 * jxl::kNumOrders * block_map.num_dc_ctxs) {
    std::fprintf(stderr, "jpeg-witness: block-context map shape is unsupported\n");
    return false;
  }
  for (size_t y = 0; y < dim.ysize_blocks; ++y) {
    for (size_t x = 0; x < dim.xsize_blocks; ++x) {
      if (shared.ac_strategy.ConstRow(y)[x].Strategy() != jxl::AcStrategyType::DCT ||
          !shared.ac_strategy.ConstRow(y)[x].IsFirstBlock() ||
          shared.raw_quant_field.ConstRow(y)[x] != 1) {
        std::fprintf(stderr, "jpeg-witness: DCT8 or quant-field guard failed\n");
        return false;
      }
    }
  }

  JxlMemoryManager memory_manager;
  JXL_RETURN_IF_ERROR(jxl::MemoryManagerInit(&memory_manager, nullptr));
  JXL_ASSIGN_OR_RETURN(
      auto input, jxl::Image::Create(&memory_manager, dim.xsize_blocks,
                                     dim.ysize_blocks, 16, 3));
  std::vector<int32_t> ac[3];
  float max_roundtrip_error = 0;
  for (size_t c = 0; c < 3; ++c) {
    const size_t jpeg_component = c < 2 ? c ^ 1 : c;
    const auto& component = jpeg.components[jpeg_component];
    const float inverse_dc_step =
        1.0f / (2040.0f / jpeg.quant[component.quant_idx].values[0]);
    for (int dc = -1024; dc <= 1023; ++dc) {
      const float recovered =
          (dc * inverse_dc_step) * shared.quantizer.GetInvDcStep(c);
      max_roundtrip_error =
          std::max(max_roundtrip_error, std::abs(recovered - dc));
      if (std::round(recovered) != dc) {
        std::fprintf(stderr, "jpeg-witness: DC roundtrip failed\n");
        return false;
      }
    }
    const size_t width = dim.xsize_blocks >> cs.HShift(c);
    const size_t height = dim.ysize_blocks >> cs.VShift(c);
    JXL_ASSIGN_OR_RETURN(
        input.channel[jpeg_component],
        jxl::Channel::Create(&memory_manager, width, height, cs.HShift(c),
                             cs.VShift(c)));
    if (component.width_in_blocks != width ||
        component.height_in_blocks != height ||
        component.coeffs.size() != width * height * 64) {
      std::fprintf(stderr, "jpeg-witness: parsed JPEG component geometry differs\n");
      return false;
    }
    ac[c].resize(width * height * 64);
    for (size_t y = 0; y < height; ++y) {
      for (size_t x = 0; x < width; ++x) {
        const auto* block = &component.coeffs[(y * width + x) * 64];
        if (block[0] < -1024 || block[0] > 1023) {
          std::fprintf(stderr, "jpeg-witness: parsed DC coefficient is out of range\n");
          return false;
        }
        input.channel[jpeg_component].Row(y)[x] = block[0];
        for (size_t ky = 0; ky < 8; ++ky) {
          for (size_t kx = 0; kx < 8; ++kx) {
            ac[c][(y * width + x) * 64 + kx * 8 + ky] =
                block[ky * 8 + kx];
          }
        }
      }
    }
  }
  if (max_roundtrip_error > 0.015687f) {
    std::fprintf(stderr, "jpeg-witness: DC roundtrip exceeds bound: %.9g\n",
                 max_roundtrip_error);
    return false;
  }

  JXL_ASSIGN_OR_RETURN(auto dc, jxl::Image3F::Create(
                                    &memory_manager, dim.xsize_blocks,
                                    dim.ysize_blocks));
  JXL_ASSIGN_OR_RETURN(auto qdc, jxl::ImageB::Create(
                                     &memory_manager, dim.xsize_blocks,
                                     dim.ysize_blocks));
  const float dc_factors[3] = {1, 1, 1};
  const float cfl_factors[3] = {0, 0, 0};
  jxl::DequantDC(jxl::Rect(0, 0, dim.xsize_blocks, dim.ysize_blocks), &dc,
                 &qdc, input, dc_factors, 1, cfl_factors, cs, block_map);

  std::vector<int64_t> buckets;
  buckets.reserve(dim.xsize_blocks * dim.ysize_blocks);
  for (size_t y = 0; y < dim.ysize_blocks; ++y) {
    for (size_t x = 0; x < dim.xsize_blocks; ++x) {
      buckets.push_back(qdc.ConstRow(y)[x]);
    }
  }
  size_t distinguishing = 0;
  size_t threshold_equalities = 0;
  for (size_t y = 0; y < dim.ysize_blocks; ++y) {
    for (size_t x = 0; x < dim.xsize_blocks; ++x) {
      for (size_t c : {0u, 2u}) {
        if ((x >> cs.HShift(c)) << cs.HShift(c) != x ||
            (y >> cs.VShift(c)) << cs.VShift(c) != y) {
          continue;
        }
        const size_t correct = block_map.Context(qdc.ConstRow(y)[x], 1, 0, c);
        const size_t wrong = block_map.Context(
            qdc.ConstRow(y >> cs.VShift(c))[x >> cs.HShift(c)], 1, 0, c);
        distinguishing += correct != wrong;
      }
      for (int threshold : block_map.dc_thresholds[1]) {
        threshold_equalities +=
            input.channel[0].Row(y)[x] == threshold;
      }
    }
  }

  out->Integers("jpeg_context.size", {static_cast<int64_t>(dim.xsize_blocks),
                                       static_cast<int64_t>(dim.ysize_blocks)});
  out->Integers("jpeg_context.group_count",
                {static_cast<int64_t>(dim.num_groups)});
  out->Integers("jpeg_context.buckets", buckets);
  out->Integers("jpeg_context.bucket_count",
                {static_cast<int64_t>(block_map.num_dc_ctxs)});
  out->Integers("jpeg_context.distinguishing_chroma_positions",
                {static_cast<int64_t>(distinguishing)});
  out->Integers("jpeg_context.threshold_equalities",
                {static_cast<int64_t>(threshold_equalities)});

  for (size_t group = 0; group < dim.num_groups; ++group) {
    const auto rect = dim.BlockGroupRect(group);
    std::vector<int32_t> group_ac[3];
    for (size_t c = 0; c < 3; ++c) {
      const size_t width = dim.xsize_blocks >> cs.HShift(c);
      const size_t group_width = rect.xsize() >> cs.HShift(c);
      const size_t group_height = rect.ysize() >> cs.VShift(c);
      const size_t x0 = rect.x0() >> cs.HShift(c);
      const size_t y0 = rect.y0() >> cs.VShift(c);
      for (size_t y = 0; y < group_height; ++y) {
        for (size_t x = 0; x < group_width; ++x) {
          const auto begin = ac[c].begin() + ((y0 + y) * width + x0 + x) * 64;
          group_ac[c].insert(group_ac[c].end(), begin, begin + 64);
        }
      }
    }
    JXL_ASSIGN_OR_RETURN(auto tmp, jxl::Image3I::Create(
                                       &memory_manager, rect.xsize(),
                                       rect.ysize()));
    const int32_t* rows[3] = {group_ac[0].data(), group_ac[1].data(),
                              group_ac[2].data()};
    std::vector<jxl::Token> tokens;
    JXL_RETURN_IF_ERROR(jxl::TokenizeCoefficients(
        shared.coeff_orders.data(), rect, rows, shared.ac_strategy, cs, &tmp,
        &tokens, qdc, shared.raw_quant_field, block_map));
    const std::string prefix = "jpeg_context.g" + std::to_string(group);
    out->Integers(prefix + ".geometry",
                  {static_cast<int64_t>(group), 0,
                   static_cast<int64_t>(rect.x0()),
                   static_cast<int64_t>(rect.y0()),
                   static_cast<int64_t>(rect.xsize()),
                   static_cast<int64_t>(rect.ysize())});
    out->Integers(prefix + ".token_count",
                  {static_cast<int64_t>(tokens.size())});
    std::vector<int64_t> values;
    values.reserve(tokens.size() * 2);
    for (const auto& token : tokens) {
      values.push_back(token.context);
      values.push_back(token.value);
    }
    out->Integers(prefix + ".tokens", values);
  }
  return true;
}

int RunJpegWitness(const std::vector<std::string>& args) {
  if (args.size() != 2) return 2;
  SemanticDumpWriter out;
  if (!Witness(args[0], args[1], &out)) {
    std::fprintf(stderr, "jpeg-witness: unsupported input or witness failed\n");
    return 1;
  }
  out.Write(stdout);
  return std::ferror(stdout) ? 1 : 0;
}

const RegisterSubcommand kRegister(
    {"jpeg-witness", "<input.jpg> <reference.jxl>", RunJpegWitness});

}  // namespace
}  // namespace harness
