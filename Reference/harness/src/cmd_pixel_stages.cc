#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <jxl/cms.h>
#include "decoded_frame.h"
#include "lib/jxl/enc_adaptive_quantization.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_cache.h"
#include "lib/jxl/enc_heuristics.h"
#include "lib/jxl/enc_frame.h"
#include "lib/jxl/enc_modular.h"
#include "lib/jxl/enc_xyb.h"
#include "lib/jxl/image_ops.h"
#include "lib/jxl/memory_manager_internal.h"
#include "registry.h"
#include "semantic_dump.h"

namespace harness {
namespace {

bool ReadPixels(const std::string& path, size_t* width, size_t* height,
                std::vector<uint8_t>* pixels) {
  std::ifstream input(path, std::ios::binary);
  std::string magic;
  unsigned max_value = 0;
  if (!(input >> magic >> *width >> *height >> max_value) || magic != "P6" ||
      max_value != 255 || *width == 0 || *height == 0) return false;
  const int separator = input.get();
  if (separator != '\n' && separator != ' ' && separator != '\t') return false;
  pixels->resize(*width * *height * 3);
  input.read(reinterpret_cast<char*>(pixels->data()), pixels->size());
  return static_cast<size_t>(input.gcount()) == pixels->size() && input.peek() == EOF;
}

jxl::Status WritePixelStages(const std::string& ppm_path,
                             const std::string& codestream_path,
                             const std::string& ac_path,
                             const std::string& dc_path,
                             const std::string& semantic_path) {
  size_t width, height;
  std::vector<uint8_t> pixels;
  if (!ReadPixels(ppm_path, &width, &height, &pixels)) return false;
  std::ifstream codestream(codestream_path, std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(codestream)), {});
  DecodedFrame decoded;
  if (!DecodeFirstFrame(bytes, &decoded)) return false;
  if (decoded.metadata.size.xsize() != width || decoded.metadata.size.ysize() != height)
    return false;

  JxlMemoryManager memory_manager;
  JXL_RETURN_IF_ERROR(jxl::MemoryManagerInit(&memory_manager, nullptr));
  auto& frame_header = decoded.header;
  const auto full = frame_header.ToFrameDimensions();
  const size_t block_count = full.xsize_blocks * full.ysize_blocks;
  std::vector<std::vector<int32_t>> ac(full.num_groups * 3);
  std::vector<int32_t> dc(block_count * 3);
  std::vector<int64_t> dc_group_info;
  std::vector<int64_t> group_dims;
  std::vector<bool> ac_seen(full.num_groups, false);
  size_t quant_mismatches = 0;

  jxl::PassesEncoderState state(&memory_manager);
  state.cparams.speed_tier = jxl::SpeedTier::kCheetah;
  state.cparams.butteraugli_distance = 1.0f;
  JXL_RETURN_IF_ERROR(jxl::ParamsPostInit(&state.cparams));
  const bool streaming = full.num_dc_groups > 1;
  state.streaming_mode = streaming;
  JXL_ASSIGN_OR_RETURN(auto modular,
                       jxl::ModularFrameEncoder::Create(
                           &memory_manager, frame_header, state.cparams, streaming));

  const size_t dc_groups_x = full.xsize_dc_groups;
  for (size_t dc_index = 0; dc_index < full.num_dc_groups; ++dc_index) {
    const size_t gx = dc_index % dc_groups_x;
    const size_t gy = dc_index / dc_groups_x;
    const size_t x0 = gx * full.dc_group_dim;
    const size_t y0 = gy * full.dc_group_dim;
    const size_t xsize = std::min(full.dc_group_dim, width - x0);
    const size_t ysize = std::min(full.dc_group_dim, height - y0);
    state.streaming_mode = streaming;
    state.initialize_global_state = dc_index == 0;
    state.dc_group_index = dc_index;

    jxl::FrameHeader patch_header = frame_header;
    patch_header.frame_size.xsize = xsize;
    patch_header.frame_size.ysize = ysize;
    JXL_RETURN_IF_ERROR(
        jxl::InitializePassesSharedState(patch_header, &state.shared, true));

    const jxl::Rect source_rect(x0, y0, xsize, ysize);
    const jxl::Rect image_bounds(0, 0, width, height);
    const jxl::Rect patch = source_rect.Extend(8, image_bounds);
    JXL_ASSIGN_OR_RETURN(
        auto image,
        jxl::Image3F::Create(&memory_manager,
                             jxl::RoundUpToBlockDim(patch.xsize()),
                             jxl::RoundUpToBlockDim(patch.ysize())));
    JXL_RETURN_IF_ERROR(image.ShrinkTo(patch.xsize(), patch.ysize()));
    for (size_t c = 0; c < 3; ++c) {
      for (size_t y = 0; y < patch.ysize(); ++y) {
        float* row = image.PlaneRow(c, y);
        for (size_t x = 0; x < patch.xsize(); ++x) {
          row[x] = pixels[((patch.y0() + y) * width + patch.x0() + x) * 3 + c] /
                   255.0f;
        }
      }
    }
    JXL_RETURN_IF_ERROR(jxl::ToXYB(jxl::ColorEncoding::SRGB(false), 255.0f,
                                   nullptr, nullptr, &image,
                                   *JxlGetDefaultCms(), nullptr));
    JXL_RETURN_IF_ERROR(jxl::PadImageToBlockMultipleInPlace(&image));
    const jxl::Rect group_rect(
        x0 - patch.x0(), y0 - patch.y0(),
        jxl::RoundUpToBlockDim(xsize), jxl::RoundUpToBlockDim(ysize));
    JXL_RETURN_IF_ERROR(jxl::LossyFrameHeuristics(
        frame_header, &state, modular.get(), nullptr, &image, group_rect,
        *JxlGetDefaultCms(), nullptr, nullptr));
    JXL_RETURN_IF_ERROR(jxl::InitializePassesEncoder(
        frame_header, image, group_rect, *JxlGetDefaultCms(), nullptr,
        &state, modular.get(), nullptr));

    const auto& local = state.shared.frame_dim;
    for (size_t y = 0; y < local.ysize_blocks; ++y) {
      for (size_t x = 0; x < local.xsize_blocks; ++x) {
        quant_mismatches += state.shared.raw_quant_field.Row(y)[x] !=
            decoded.state->shared->raw_quant_field.Row(y)[x + x0 / 8];
      }
    }
    const auto params = state.shared.quantizer.GetParams();
    const auto public_params = decoded.state->shared->quantizer.GetParams();
    if (params.global_scale != public_params.global_scale ||
        params.quant_dc != public_params.quant_dc) return false;

    for (size_t local_group = 0; local_group < local.num_groups; ++local_group) {
      const size_t absolute_group = modular->ComputeStreamingAbsoluteAcGroupId(
          dc_index, local_group, local);
      if (absolute_group >= full.num_groups || ac_seen[absolute_group]) return false;
      ac_seen[absolute_group] = true;
      const auto rect = local.BlockGroupRect(local_group);
      const size_t count = rect.xsize() * rect.ysize() * 64;
      for (size_t c = 0; c < 3; ++c) {
        const int32_t* row = state.coeffs[0]->PlaneRow(c, local_group, 0).ptr32;
        ac[absolute_group * 3 + c].assign(row, row + count);
      }
      group_dims.push_back(absolute_group);
      group_dims.push_back(rect.xsize());
      group_dims.push_back(rect.ysize());
    }

    jxl::BitWriter writer(&memory_manager);
    JXL_RETURN_IF_ERROR(modular->EncodeStream(
        &writer, nullptr, jxl::LayerType::Dc,
        jxl::ModularStreamId::VarDCTDC(dc_index)));
    writer.ZeroPadToByte();
    JXL_ASSIGN_OR_RETURN(
        auto integers,
        jxl::Image::Create(&memory_manager, local.xsize_blocks,
                           local.ysize_blocks, 8, 3));
    jxl::BitReader reader(writer.GetSpan());
    jxl::ModularOptions options;
    const auto status = jxl::ModularGenericDecompress(
        &reader, integers, nullptr,
        jxl::ModularStreamId::VarDCTDC(dc_index).ID(full), &options);
    const bool closed = reader.Close();
    JXL_RETURN_IF_ERROR(status);
    JXL_ENSURE(closed);
    for (size_t c = 0; c < 3; ++c) {
      const size_t stored_channel = c < 2 ? c ^ 1 : c;
      for (size_t y = 0; y < local.ysize_blocks; ++y) {
        for (size_t x = 0; x < local.xsize_blocks; ++x) {
          const size_t dst = c * block_count + (y0 / 8 + y) * full.xsize_blocks + x0 / 8 + x;
          dc[dst] = integers.channel[stored_channel].Row(y)[x];
        }
      }
    }
    dc_group_info.insert(dc_group_info.end(), {
        static_cast<int64_t>(dc_index), static_cast<int64_t>(state.initialize_global_state),
        static_cast<int64_t>(patch.x0()), static_cast<int64_t>(patch.y0()),
        static_cast<int64_t>(patch.xsize()), static_cast<int64_t>(patch.ysize()),
        static_cast<int64_t>(image.xsize()), static_cast<int64_t>(image.ysize()),
        static_cast<int64_t>(group_rect.x0()), static_cast<int64_t>(group_rect.y0()),
        static_cast<int64_t>(local.xsize_blocks), static_cast<int64_t>(local.ysize_blocks)});
    modular->ClearStreamData(jxl::ModularStreamId::VarDCTDC(dc_index));
    modular->ClearModularStreamData();
  }
  if (quant_mismatches != 0 ||
      std::find(ac_seen.begin(), ac_seen.end(), false) != ac_seen.end()) return false;

  std::ofstream ac_file(ac_path, std::ios::binary);
  std::ofstream dc_file(dc_path, std::ios::binary);
  if (!ac_file || !dc_file) return false;
  for (const auto& group : ac) ac_file.write(reinterpret_cast<const char*>(group.data()), group.size() * sizeof(int32_t));
  dc_file.write(reinterpret_cast<const char*>(dc.data()), dc.size() * sizeof(int32_t));
  ac_file.close(); dc_file.close();
  if (ac_file.fail() || dc_file.fail()) return false;

  SemanticDumpWriter dump;
  dump.Integers("pixel_stages.dimensions", {
      static_cast<int64_t>(width), static_cast<int64_t>(height),
      static_cast<int64_t>(full.xsize_blocks), static_cast<int64_t>(full.ysize_blocks),
      static_cast<int64_t>(full.num_groups), static_cast<int64_t>(full.num_dc_groups)});
  dump.Integers("pixel_stages.ac_group_block_dims", group_dims);
  dump.Integers("pixel_stages.dc_group_lifecycle", dc_group_info);
  dump.Integers("pixel_stages.quant_field_mismatches", {static_cast<int64_t>(quant_mismatches)});
  FILE* file = std::fopen(semantic_path.c_str(), "w");
  if (file == nullptr) return false;
  dump.Write(file);
  return std::fclose(file) == 0;
}

int RunPixelStages(const std::vector<std::string>& args) {
  if (args.size() != 5) return 2;
  return WritePixelStages(args[0], args[1], args[2], args[3], args[4]) ? 0 : 1;
}

const RegisterSubcommand kRegister(
    {"pixel-stages", "<input.ppm> <reference.jxl> <ac.bin> <dc.bin> <out.sem>", RunPixelStages});

}  // namespace
}  // namespace harness
