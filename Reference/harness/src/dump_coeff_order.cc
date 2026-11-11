// Semantic dump category "coeff_order"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {}

const RegisterDumpCategory kRegister({"coeff_order", Dump});

}  // namespace
}  // namespace harness
