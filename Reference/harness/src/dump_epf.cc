#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("epf.iterations", {frame.header.loop_filter.epf_iters});
}

void DumpSharpness(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& image = frame.state->shared_storage.epf_sharpness;
  std::vector<int64_t> values;
  values.reserve(image.xsize() * image.ysize());
  for (size_t y = 0; y < image.ysize(); ++y) {
    for (size_t x = 0; x < image.xsize(); ++x) values.push_back(image.Row(y)[x]);
  }
  out.Integers("epf_sharpness.dimensions",
               {static_cast<int64_t>(image.xsize()),
                static_cast<int64_t>(image.ysize())});
  out.Integers("epf_sharpness.values", values);
}

const RegisterDumpCategory kRegister({"epf", Dump});
const RegisterDumpCategory kRegisterSharpness({"epf_sharpness", DumpSharpness});

}  // namespace
}  // namespace harness
