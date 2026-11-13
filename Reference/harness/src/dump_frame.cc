// Semantic dump category "frame"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& h = frame.header; const auto d = h.ToFrameDimensions();
  out.Integers("frame.encoding", {static_cast<int64_t>(h.encoding)});
  out.Integers("frame.groups", {static_cast<int64_t>(d.num_groups)});
  out.Integers("frame.dc_groups", {static_cast<int64_t>(d.num_dc_groups)});
  out.Integers("frame.passes", {h.passes.num_passes});
}

const RegisterDumpCategory kRegister({"frame", Dump});

}  // namespace
}  // namespace harness
