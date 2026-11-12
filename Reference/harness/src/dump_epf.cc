#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("epf.iterations", {frame.header.loop_filter.epf_iters});
}

const RegisterDumpCategory kRegister({"epf", Dump});

}  // namespace
}  // namespace harness
