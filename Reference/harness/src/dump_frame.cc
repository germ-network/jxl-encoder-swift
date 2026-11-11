// Semantic dump category "frame"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {}

const RegisterDumpCategory kRegister({"frame", Dump});

}  // namespace
}  // namespace harness
