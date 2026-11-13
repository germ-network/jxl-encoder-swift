#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("b_matrix_scale.value", {frame.header.b_qm_scale});
}

const RegisterDumpCategory kRegister({"b_matrix_scale", Dump});

}  // namespace
}  // namespace harness
