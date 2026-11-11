// stages <stage> <in.dump> <out.dump>: encoder-side intermediate stages of the
// pinned libjxl's e4 pixel path on a linear float input.
//   linear  passthrough (records the input; no libjxl stage)
//   xyb     ToXYB on the whole frame
//   dct     ToXYB, PadImageToBlockMultipleInPlace, then the DCT8 of every
//           block in block-raster order
#include <cstdio>

#include "lib/jxl/enc_transforms.h"
#include "lib/jxl/enc_xyb.h"
#include "lib/jxl/image_ops.h"
#include "registry.h"
#include "stage_dump.h"

namespace harness {
namespace {

int RunStages(const std::vector<std::string>& args) {
  std::fprintf(stderr, "stages: unimplemented\n");
  return 1;
}

const RegisterSubcommand kRegister(
    {"stages", "<linear|xyb|dct> <in.dump> <out.dump>", RunStages});

}  // namespace
}  // namespace harness
