#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  out.Integers("x_matrix_scale.value", {frame.header.x_qm_scale});
}

const RegisterDumpCategory kRegister({"x_matrix_scale", Dump});

}  // namespace
}  // namespace harness
