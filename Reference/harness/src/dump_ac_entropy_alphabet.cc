// Semantic dump category for the retained ANS alphabet setting.
#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& code = frame.state->code[0];
  out.Integers("ac_entropy_alphabet.ans_log_alpha_size",
               code.use_prefix_code ? std::vector<int64_t>{}
                                    : std::vector<int64_t>{code.log_alpha_size});
}

const RegisterDumpCategory kRegister({"ac_entropy_alphabet", Dump});

}  // namespace
}  // namespace harness
