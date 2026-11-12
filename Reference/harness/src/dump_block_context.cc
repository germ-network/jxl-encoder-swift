// Semantic dump category "block_context"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& map = frame.state->shared->block_ctx_map;
  for (size_t c = 0; c < 3; ++c) out.Integers("block_context.dc_thresholds.c"+std::to_string(c), std::vector<int64_t>(map.dc_thresholds[c].begin(),map.dc_thresholds[c].end()));
  out.Integers("block_context.qf_thresholds", std::vector<int64_t>(map.qf_thresholds.begin(),map.qf_thresholds.end()));
  out.Integers("block_context.ctx_map", std::vector<int64_t>(map.ctx_map.begin(),map.ctx_map.end()));
  out.Integers("block_context.num_ctxs", {static_cast<int64_t>(map.num_ctxs)});
}

const RegisterDumpCategory kRegister({"block_context", Dump});

}  // namespace
}  // namespace harness
