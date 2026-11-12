#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("gaborish.enabled", {frame.header.loop_filter.gab});
}

const RegisterDumpCategory kRegister({"gaborish", Dump});

}  // namespace
}  // namespace harness
