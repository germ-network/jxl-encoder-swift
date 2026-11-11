// Semantic dump category "quant_field"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {}

const RegisterDumpCategory kRegister({"quant_field", Dump});

}  // namespace
}  // namespace harness
