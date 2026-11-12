// Semantic dump category "context_map"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& shared = *frame.state->shared;
  const auto& map = frame.state->context_map[0];
  const size_t count = shared.num_histograms * shared.block_ctx_map.NumACContexts();
  out.Integers("context_map.num_histograms", {static_cast<int64_t>(shared.num_histograms)});
  out.Integers("context_map.ac", std::vector<int64_t>(map.begin(),map.begin()+count));
}

const RegisterDumpCategory kRegister({"context_map", Dump});

}  // namespace
}  // namespace harness
