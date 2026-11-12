#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& depth = frame.metadata.m.bit_depth;
  out.Integers("image_sample_format.floating_point", {depth.floating_point_sample});
  out.Integers("image_sample_format.bits_per_sample", {depth.bits_per_sample});
  out.Integers("image_sample_format.exponent_bits_per_sample", {depth.exponent_bits_per_sample});
}

const RegisterDumpCategory kRegister({"image_sample_format", Dump});

}  // namespace
}  // namespace harness
