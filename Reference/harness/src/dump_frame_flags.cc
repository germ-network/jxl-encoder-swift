#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("frame_flags.flags", {static_cast<int64_t>(frame.header.flags)});
}

const RegisterDumpCategory kRegister({"frame_flags", Dump});

}  // namespace
}  // namespace harness
