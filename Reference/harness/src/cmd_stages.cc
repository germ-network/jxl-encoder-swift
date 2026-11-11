// stages <stage> <in.dump> <out.dump>: encoder-side intermediate stages of the
// pinned libjxl's e4 pixel path on a linear float input.
//   linear  passthrough (records the input; no libjxl stage)
//   xyb     ToXYB on the whole frame
//   dct     ToXYB, PadImageToBlockMultipleInPlace, then the DCT8 of every
//           block in block-raster order
#include <cstdio>
#include <cstring>
#include <jxl/cms.h>
#include "lib/jxl/ac_strategy.h"

#include "lib/jxl/enc_transforms.h"
#include "lib/jxl/enc_xyb.h"
#include "lib/jxl/image_ops.h"
#include "registry.h"
#include "stage_dump.h"

namespace harness {
namespace {

jxl::Status Stages(const std::string& stage, const std::string& input, const std::string& output) {
  jxl::Image3F image;
  if (!ReadStageDump(input, &image)) return false;
  if (stage == "linear") return WriteStageDump(output, image);
  if (stage != "xyb" && stage != "dct") return false;
  if (stage == "dct") {
    const size_t xs = image.xsize(), ys = image.ysize();
    jxl::Image3F padded;
    JXL_ASSIGN_OR_RETURN(padded, jxl::Image3F::Create(image.memory_manager(), (xs + 7) / 8 * 8, (ys + 7) / 8 * 8));
    JXL_RETURN_IF_ERROR(padded.ShrinkTo(xs, ys));
    for (size_t c = 0; c < 3; ++c) for (size_t y = 0; y < ys; ++y) std::memcpy(padded.PlaneRow(c, y), image.PlaneRow(c, y), xs * sizeof(float));
    image = std::move(padded);
  }
  JXL_RETURN_IF_ERROR(jxl::ToXYB(jxl::ColorEncoding::LinearSRGB(), 255, nullptr, nullptr, &image, *JxlGetDefaultCms(), nullptr));
  if (stage == "xyb") return WriteStageDump(output, image);
  JXL_RETURN_IF_ERROR(jxl::PadImageToBlockMultipleInPlace(&image));
  jxl::Image3F coefficients;
  JXL_ASSIGN_OR_RETURN(coefficients, jxl::Image3F::Create(image.memory_manager(), image.xsize() * image.ysize(), 1));
  // The block transform also uses recursive 1D temporaries after its block buffer.
  alignas(64) float scratch[4 * 64];
  for (size_t c = 0; c < 3; ++c) {
    size_t offset = 0;
    for (size_t y = 0; y < image.ysize(); y += 8) for (size_t x = 0; x < image.xsize(); x += 8) {
      jxl::TransformFromPixels(jxl::AcStrategyType::DCT, image.PlaneRow(c, y) + x, image.PixelsPerRow(), coefficients.PlaneRow(c, 0) + offset, scratch);
      offset += 64;
    }
  }
  return WriteStageDump(output, coefficients);
}
int RunStages(const std::vector<std::string>& args) {
  if (args.size() != 3) return 2;
  if (Stages(args[0], args[1], args[2])) return 0;
  std::fprintf(stderr, "stages: invalid input or stage failed\n");
  return 1;
}

const RegisterSubcommand kRegister(
    {"stages", "<linear|xyb|dct> <in.dump> <out.dump>", RunStages});

}  // namespace
}  // namespace harness
