// Dumps libjxl-tiny's intermediate stages as raw float32 planes, so the Swift
// port can be diffed against the reference stage by stage.
//
// Deliberately links the upstream static library rather than patching the
// vendored checkout, so tiny stays a clean clone that can be updated.

#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "tools/dump_stages.cc"
#include <hwy/foreach_target.h>
#include <hwy/highway.h>

#include "encoder/enc_transforms-inl.h"

HWY_BEFORE_NAMESPACE();
namespace jxl {
namespace HWY_NAMESPACE {

// Forward DCT of every 8x8 block, written back in block-raster order: block
// (bx, by) occupies 64 consecutive floats. The Swift port uses the same layout.
void DCT8BlocksImpl(const float* pixels, size_t xsize, size_t ysize,
                    float* out) {
  HWY_ALIGN float scratch[64];
  const size_t blocks_x = xsize / 8;
  const size_t blocks_y = ysize / 8;
  for (size_t by = 0; by < blocks_y; ++by) {
    for (size_t bx = 0; bx < blocks_x; ++bx) {
      const float* src = pixels + by * 8 * xsize + bx * 8;
      float* dst = out + (by * blocks_x + bx) * 64;
      TransformFromPixels(AcStrategy::Type::DCT, src, xsize, dst, scratch);
    }
  }
}

}  // namespace HWY_NAMESPACE
}  // namespace jxl
HWY_AFTER_NAMESPACE();

#if HWY_ONCE

#include "encoder/common.h"
#include "encoder/enc_adaptive_quantization.h"
#include "encoder/enc_frame.h"
#include "encoder/enc_group.h"
#include "encoder/enc_xyb.h"
#include "encoder/image.h"
#include "encoder/quant_weights.h"
#include "encoder/read_pfm.h"

namespace jxl {
HWY_EXPORT(DCT8BlocksImpl);
void DCT8Blocks(const float* pixels, size_t xsize, size_t ysize, float* out) {
  HWY_DYNAMIC_DISPATCH(DCT8BlocksImpl)(pixels, xsize, ysize, out);
}
}  // namespace jxl

namespace {

bool WritePlanes(const std::string& path, size_t xsize, size_t ysize,
                 const std::vector<std::vector<float>>& planes) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", path.c_str());
    return false;
  }
  const uint32_t magic = 0x304D5544;  // "DUM0"
  const uint32_t xs = xsize, ys = ysize,
                 channels = static_cast<uint32_t>(planes.size());
  fwrite(&magic, 4, 1, f);
  fwrite(&xs, 4, 1, f);
  fwrite(&ys, 4, 1, f);
  fwrite(&channels, 4, 1, f);
  for (const auto& p : planes) fwrite(p.data(), sizeof(float), p.size(), f);
  fclose(f);
  return true;
}

std::vector<std::vector<float>> Flatten(const jxl::Image3F& img) {
  std::vector<std::vector<float>> planes(3);
  for (size_t c = 0; c < 3; ++c) {
    planes[c].resize(img.xsize() * img.ysize());
    for (size_t y = 0; y < img.ysize(); ++y) {
      memcpy(planes[c].data() + y * img.xsize(), img.PlaneRow(c, y),
             img.xsize() * sizeof(float));
    }
  }
  return planes;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <stage> <in.pfm> <out.dump>\n", argv[0]);
    fprintf(stderr, "  stages: linear, xyb, dct, quant, stripe, aq\n");
    return 1;
  }
  const std::string stage = argv[1];

  jxl::Image3F image;
  if (!jxl::ReadPFM(argv[2], &image)) {
    fprintf(stderr, "failed to read %s\n", argv[2]);
    return 1;
  }
  const size_t xsize = image.xsize(), ysize = image.ysize();

  std::vector<std::vector<float>> planes;
  if (stage == "linear") {
    planes = Flatten(image);
  } else if (stage == "xyb") {
    jxl::ToXYB(&image);
    planes = Flatten(image);
  } else if (stage == "stripe") {
    // The real pipeline geometry: walk kGroupDim x kTileDim stripes, pad each
    // to whole blocks by edge replication (the reference's own
    // CopyAndPadImage), XYB the padded stripe, then DCT it. Emitted as one
    // concatenated buffer per channel in stripe order, so a port with the
    // wrong padding, stripe shape, or ordering cannot match.
    const size_t xsize_groups = (xsize + jxl::kGroupDim - 1) / jxl::kGroupDim;
    const size_t ysize_tiles = (ysize + jxl::kTileDim - 1) / jxl::kTileDim;
    planes.assign(3, {});
    jxl::Image3F stripe(jxl::kGroupDim, jxl::kTileDim + jxl::kBlockDim);
    for (size_t gx = 0; gx < xsize_groups; ++gx) {
      for (size_t ty = 0; ty < ysize_tiles; ++ty) {
        jxl::Rect rect(gx * jxl::kGroupDim, ty * jxl::kTileDim, jxl::kGroupDim,
                       jxl::kTileDim, xsize, ysize);
        jxl::CopyAndPadImageForTest(image, rect, &stripe);
        jxl::ToXYB(&stripe);
        const size_t sw = stripe.xsize(), sh = stripe.ysize();
        auto flat = Flatten(stripe);
        for (size_t c = 0; c < 3; ++c) {
          std::vector<float> coeffs(sw * sh);
          jxl::DCT8Blocks(flat[c].data(), sw, sh, coeffs.data());
          planes[c].insert(planes[c].end(), coeffs.begin(), coeffs.end());
        }
      }
    }
    // shape is the concatenation itself, so report a flat N x 1 buffer
    if (!WritePlanes(argv[3], planes[0].size(), 1, planes)) return 1;
    fprintf(stderr, "stripe: %zux%zu -> %s (%zu floats/channel)\n", xsize, ysize,
            argv[3], planes[0].size());
    return 0;
  } else if (stage == "aq" || stage == "aqf" || stage == "aqe" || stage == "aqp") {
    // Adaptive quant field over the real stripe/tile walk. The exported
    // ComputeAdaptiveQuantFieldTile is called with the same buffer shapes the
    // encoder uses (TileProcessorMemory), so this exercises the shipped path.
    const float distance = 1.0f;
    const float inv_scale = 1.0f / 0.1120758056640625f;
    const size_t xsize_groups = (xsize + jxl::kGroupDim - 1) / jxl::kGroupDim;
    const size_t ysize_tiles = (ysize + jxl::kTileDim - 1) / jxl::kTileDim;
    const size_t xsize_blocks = (xsize + 7) / 8;
    const size_t ysize_blocks = (ysize + 7) / 8;

    jxl::ImageB raw_quant_field(xsize_blocks, ysize_blocks);
    jxl::ImageF quant_field(jxl::kTileDimInBlocks, jxl::kTileDimInBlocks);
    jxl::ImageF masking(jxl::kTileDimInBlocks, jxl::kTileDimInBlocks);
    jxl::ImageF pre_erosion(jxl::kTileDimInBlocks * 2 + 2,
                            jxl::kTileDimInBlocks * 2 + 2);
    jxl::ImageF diff_buffer(jxl::kTileDim + 8, 1);
    jxl::Image3F stripe(jxl::kGroupDim, jxl::kTileDim + jxl::kBlockDim);
    std::vector<float> float_field(xsize_blocks * ysize_blocks, 0.f);

    for (size_t gx = 0; gx < xsize_groups; ++gx) {
      for (size_t ty = 0; ty < ysize_tiles; ++ty) {
        jxl::Rect rect(gx * jxl::kGroupDim, ty * jxl::kTileDim, jxl::kGroupDim,
                       jxl::kTileDim, xsize, ysize);
        jxl::CopyAndPadImageForTest(image, rect, &stripe);
        jxl::ToXYB(&stripe);
        const size_t sw = stripe.xsize(), sh = stripe.ysize();
        jxl::Rect stripe_brect(gx * jxl::kGroupDimInBlocks,
                               ty * jxl::kTileDimInBlocks,
                               jxl::kGroupDimInBlocks, jxl::kTileDimInBlocks,
                               xsize_blocks, ysize_blocks);
        const size_t tiles_x = (sw + jxl::kTileDim - 1) / jxl::kTileDim;
        for (size_t tx = 0; tx < tiles_x; ++tx) {
          jxl::Rect tile_brect(tx * jxl::kTileDimInBlocks, 0,
                               jxl::kTileDimInBlocks, jxl::kTileDimInBlocks,
                               sw / 8, sh / 8);
          jxl::ComputeAdaptiveQuantFieldTile(
              stripe, tile_brect, stripe_brect, distance, inv_scale,
              &pre_erosion, diff_buffer.Row(0), &quant_field, &masking,
              &raw_quant_field);
          if (stage == "aqp" && gx == 0 && ty == 0 && tx == 0) {
            std::vector<std::vector<float>> pe(1);
            const size_t pw = pre_erosion.xsize(), ph = pre_erosion.ysize();
            pe[0].resize(pw * ph);
            for (size_t yy = 0; yy < ph; ++yy)
              for (size_t xx = 0; xx < pw; ++xx)
                pe[0][yy * pw + xx] = pre_erosion.Row(yy)[xx];
            WritePlanes(argv[3], pw, ph, pe);
            fprintf(stderr, "aqp: pre_erosion %zux%zu -> %s\n", pw, ph, argv[3]);
            return 0;
          }
          for (size_t yy = 0; yy < tile_brect.ysize(); ++yy) {
            for (size_t xx = 0; xx < tile_brect.xsize(); ++xx) {
              size_t bx = gx * jxl::kGroupDimInBlocks + tile_brect.x0() + xx;
              size_t by = ty * jxl::kTileDimInBlocks + yy;
              if (bx < xsize_blocks && by < ysize_blocks) {
                float_field[by * xsize_blocks + bx] =
                    stage == "aqe" ? (1.0f / masking.Row(yy)[xx] - 0.001f)
                                   : quant_field.Row(yy)[xx];
              }
            }
          }
        }
      }
    }

    planes.assign(1, std::vector<float>(xsize_blocks * ysize_blocks));
    for (size_t y = 0; y < ysize_blocks; ++y) {
      for (size_t x = 0; x < xsize_blocks; ++x) {
        planes[0][y * xsize_blocks + x] =
            (stage == "aqf" || stage == "aqe") ? float_field[y * xsize_blocks + x]
                           : raw_quant_field.Row(y)[x];
      }
    }
    if (!WritePlanes(argv[3], xsize_blocks, ysize_blocks, planes)) return 1;
    fprintf(stderr, "aq: %zux%zu -> %s (%zux%zu blocks)\n", xsize, ysize,
            argv[3], xsize_blocks, ysize_blocks);
    return 0;
  } else if (stage == "quant") {
    // Quantized AC coefficients at a fixed quant/scale, so the quantizer can be
    // diffed independently of the adaptive quant field. Values chosen to
    // straddle the zero-threshold logic.
    if (xsize % 8 || ysize % 8) {
      fprintf(stderr, "quant stage requires dimensions divisible by 8\n");
      return 1;
    }
    const float scale = 0.1120758056640625f;  // global_scale 7345 / 2^16, arbitrary but fixed
    const int32_t quant = 5;
    jxl::DequantMatrices matrices;
    jxl::ToXYB(&image);
    auto xyb = Flatten(image);
    planes.resize(3);
    for (size_t c = 0; c < 3; ++c) {
      std::vector<float> coeffs(xsize * ysize);
      jxl::DCT8Blocks(xyb[c].data(), xsize, ysize, coeffs.data());
      const float* qm = matrices.InvMatrix(0, c);
      planes[c].resize(xsize * ysize);
      std::vector<int32_t> out(64);
      for (size_t b = 0; b < xsize * ysize / 64; ++b) {
        jxl::QuantizeBlockACForTest(coeffs.data() + b * 64, c, qm, quant, scale,
                                    1.0f, 1, 1, out.data());
        for (size_t i = 0; i < 64; ++i) {
          planes[c][b * 64 + i] = static_cast<float>(out[i]);
        }
      }
    }
  } else if (stage == "dct") {
    if (xsize % 8 || ysize % 8) {
      fprintf(stderr, "dct stage requires dimensions divisible by 8\n");
      return 1;
    }
    jxl::ToXYB(&image);
    auto xyb = Flatten(image);
    planes.resize(3);
    for (size_t c = 0; c < 3; ++c) {
      planes[c].resize(xsize * ysize);
      jxl::DCT8Blocks(xyb[c].data(), xsize, ysize, planes[c].data());
    }
  } else {
    fprintf(stderr, "unknown stage: %s\n", stage.c_str());
    return 1;
  }

  if (!WritePlanes(argv[3], xsize, ysize, planes)) return 1;
  fprintf(stderr, "%s: %zux%zu -> %s\n", stage.c_str(), xsize, ysize, argv[3]);
  return 0;
}
#endif  // HWY_ONCE
