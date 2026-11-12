// Semantic dump category "quant_field"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& shared = *frame.state->shared;
  const auto& field = shared.raw_quant_field;
  std::vector<int64_t> values;
  for (size_t y = 0; y < field.ysize(); ++y) for (size_t x = 0; x < field.xsize(); ++x) values.push_back(field.Row(y)[x]);
  const auto params = shared.quantizer.GetParams();
  out.Integers("quant_field.raw", values);
  out.Integers("quant_field.global_scale", {params.global_scale});
  out.Integers("quant_field.quant_dc", {params.quant_dc});
}

const RegisterDumpCategory kRegister({"quant_field", Dump});

}  // namespace
}  // namespace harness
