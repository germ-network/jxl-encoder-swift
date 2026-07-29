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
    fprintf(stderr, "  stages: linear, xyb, dct, quant\n");
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
