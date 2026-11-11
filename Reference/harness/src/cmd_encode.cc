// encode <in.ppm|in.dump> <distance> <out.jxl>: the pinned libjxl's
// `cjxl -d <distance> -e 4 --container=0` equivalent through the public
// JxlEncoder API, so the encode runs on the harness's SIMD target. 8-bit PPM
// input is sRGB; .dump input is linear float with a linear transfer function.
#include <cstdio>

#include "jxl/encode.h"
#include "registry.h"

namespace harness {
namespace {

int RunEncode(const std::vector<std::string>& args) {
  std::fprintf(stderr, "encode: unimplemented\n");
  return 1;
}

const RegisterSubcommand kRegister(
    {"encode", "<in.ppm|in.dump> <distance> <out.jxl>", RunEncode});

}  // namespace
}  // namespace harness
