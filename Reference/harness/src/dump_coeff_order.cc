// Semantic dump category "coeff_order"; fields are listed in Reference/semantic-dump.md.
#include "decoded_frame.h"
#include "registry.h"
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/coeff_order.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& orders = frame.state->shared->coeff_orders;
  jxl::coeff_order_t natural[64];
  jxl::AcStrategy::FromRawStrategy(0).ComputeNaturalCoeffOrder(natural);
  bool nondefault = false;
  for (size_t c = 0; c < 3; ++c) {
    const auto* order = orders.data() + jxl::kCoeffOrderOffset[c] * jxl::kDCTBlockSize;
    for (size_t i = 0; i < 64; ++i) if (order[i] != natural[i]) nondefault = true;
    out.Integers("coeff_order.dct8.c"+std::to_string(c), std::vector<int64_t>(order, order+64));
  }
  out.Integers("coeff_order.nondefault_orders", {nondefault ? 1 : 0});
}

const RegisterDumpCategory kRegister({"coeff_order", Dump});

}  // namespace
}  // namespace harness
