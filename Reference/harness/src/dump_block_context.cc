// Semantic dump category "block_context"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {}

const RegisterDumpCategory kRegister({"block_context", Dump});

}  // namespace
}  // namespace harness
