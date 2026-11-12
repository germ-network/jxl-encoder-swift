// Semantic dump category "context_map"; fields are listed in Reference/semantic-dump.md.
#include <algorithm>
#include "decoded_frame.h"
#include <cstdio>
#include <cstdlib>
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& shared = *frame.state->shared;
  const auto& map = frame.state->context_map[0];
  const size_t count = shared.num_histograms * shared.block_ctx_map.NumACContexts();
  const size_t table_count = frame.state->code[0].uint_config.size();
  if (map.size() < count || table_count == 0 ||
      !std::all_of(map.begin(), map.begin() + count,
                   [table_count](uint8_t value) { return value < table_count; })) {
    std::fprintf(stderr, "dump context_map: invalid AC context map\n");
    std::exit(1);
  }
  out.Integers("context_map.num_histograms", {static_cast<int64_t>(shared.num_histograms)});
  out.Integers("context_map.ac", std::vector<int64_t>(map.begin(),map.begin()+count));
}

const RegisterDumpCategory kRegister({"context_map", Dump});

}  // namespace
}  // namespace harness
