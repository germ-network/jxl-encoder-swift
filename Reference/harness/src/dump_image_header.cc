#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void Dump(const DecodedFrame& frame, SemanticDumpWriter& out) {
  const auto& metadata = frame.metadata.m;
  const auto& color = metadata.color_encoding;
  out.Integers("image_header.size", {static_cast<int64_t>(frame.metadata.xsize()), static_cast<int64_t>(frame.metadata.ysize())});
  out.Integers("image_header.transfer_function", {static_cast<int64_t>(color.Tf().transfer_function)});
  out.Integers("image_header.color_space", {static_cast<int64_t>(color.GetColorSpace())});
  out.Integers("image_header.white_point", {static_cast<int64_t>(color.GetWhitePointType())});
  out.Integers("image_header.primaries", {static_cast<int64_t>(color.GetPrimariesType())});
  out.Integers("image_header.rendering_intent", {static_cast<int64_t>(color.GetRenderingIntent())});
  out.Integers("image_header.xyb", {metadata.xyb_encoded});
  out.Integers("image_header.num_extra_channels", {static_cast<int64_t>(metadata.num_extra_channels)});
}

const RegisterDumpCategory kRegister({"image_header", Dump});

}  // namespace
}  // namespace harness
