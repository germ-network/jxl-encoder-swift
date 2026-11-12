#include "decoded_frame.h"
#include <cstdio>
#include <cstdlib>
#include "lib/jxl/dec_frame.h"
#include "lib/jxl/headers.h"
#include "lib/jxl/icc_codec.h"
#include "lib/jxl/memory_manager_internal.h"
namespace harness {
namespace {
jxl::Status Decode(const std::vector<uint8_t>& bytes, DecodedFrame* frame) {
  // Retained decoder images refer to this allocator after this function returns.
  static JxlMemoryManager manager = [] { JxlMemoryManager m; if (!jxl::MemoryManagerInit(&m, nullptr)) std::abort(); return m; }();
  jxl::Status closed = true; size_t offset;
  {
    jxl::BitReader reader(jxl::Bytes(bytes.data(), bytes.size()));
    jxl::BitReaderScopedCloser closer(reader, closed);
    if (reader.ReadFixedBits<16>() != 0x0AFF) return false;
    JXL_RETURN_IF_ERROR(jxl::ReadSizeHeader(&reader, &frame->metadata.size));
    JXL_RETURN_IF_ERROR(jxl::ReadImageMetadata(&reader, &frame->metadata.m));
    frame->metadata.transform_data.nonserialized_xyb_encoded = frame->metadata.m.xyb_encoded;
    JXL_RETURN_IF_ERROR(jxl::Bundle::Read(&reader, &frame->metadata.transform_data));
    if (frame->metadata.m.color_encoding.WantICC()) {
      jxl::ICCReader icc_reader(&manager); jxl::PaddedBytes icc(&manager);
      JXL_RETURN_IF_ERROR(icc_reader.Init(&reader));
      JXL_RETURN_IF_ERROR(icc_reader.Process(&reader, &icc));
      frame->metadata.m.color_encoding.SetICCRaw(std::vector<uint8_t>(icc.begin(), icc.end()));
    }
    if (frame->metadata.m.have_preview) return false;
    JXL_RETURN_IF_ERROR(reader.JumpToByteBoundary());
    offset = reader.TotalBitsConsumed()/8;
  }
  if (!closed || offset >= bytes.size()) return false;
  frame->state = std::make_unique<jxl::PassesDecoderState>(&manager);
  jxl::ImageBundle image(&manager, &frame->metadata.m);
  JXL_RETURN_IF_ERROR(jxl::DecodeFrame(frame->state.get(), nullptr, bytes.data()+offset, bytes.size()-offset, &frame->header, &image, frame->metadata));
  // These dump categories describe the single-pass DCT8 pixel path.
  return frame->header.encoding == jxl::FrameEncoding::kVarDCT && frame->header.passes.num_passes == 1 && frame->state->used_acs == 1;
}
}
bool DecodeFirstFrame(const std::vector<uint8_t>& codestream, DecodedFrame* frame) {
  if (Decode(codestream, frame)) return true;
  std::fprintf(stderr, "dump: invalid or unsupported first frame\n"); return false;
}
}  // namespace harness
