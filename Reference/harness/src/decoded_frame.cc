#include "decoded_frame.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include "lib/jxl/dec_frame.h"
#include "lib/jxl/headers.h"
#include "lib/jxl/icc_codec.h"
#include "lib/jxl/memory_manager_internal.h"
namespace harness {
namespace {

uint32_t ReadBE32(const uint8_t* data) {
  return (uint32_t(data[0]) << 24) | (uint32_t(data[1]) << 16) |
         (uint32_t(data[2]) << 8) | uint32_t(data[3]);
}

uint64_t ReadBE64(const uint8_t* data) {
  return (uint64_t(ReadBE32(data)) << 32) | ReadBE32(data + 4);
}

bool ExtractCodestream(const std::vector<uint8_t>& input,
                       std::vector<uint8_t>* codestream) {
  if (input.size() >= 2 && input[0] == 0xFF && input[1] == 0x0A) {
    *codestream = input;
    return true;
  }
  static constexpr uint8_t kSignature[] = {0x00, 0x00, 0x00, 0x0C, 'J', 'X',
                                            'L',  ' ',  '\r', '\n', 0x87, '\n'};
  if (input.size() < sizeof(kSignature) ||
      std::memcmp(input.data(), kSignature, sizeof(kSignature)) != 0) {
    return false;
  }

  std::vector<uint8_t> single;
  std::vector<std::pair<uint32_t, std::vector<uint8_t>>> fragments;
  bool saw_single = false;
  bool first_box = true;
  size_t offset = sizeof(kSignature);
  while (offset < input.size()) {
    if (input.size() - offset < 8) return false;
    const uint32_t short_size = ReadBE32(input.data() + offset);
    const uint8_t* type = input.data() + offset + 4;
    size_t header = 8;
    uint64_t box_size = short_size;
    if (short_size == 1) {
      if (input.size() - offset < 16) return false;
      box_size = ReadBE64(input.data() + offset + 8);
      header = 16;
    } else if (short_size == 0) {
      box_size = input.size() - offset;
    }
    if (box_size < header || box_size > input.size() - offset) return false;
    const size_t payload_size = static_cast<size_t>(box_size) - header;
    const uint8_t* payload = input.data() + offset + header;
    if (first_box) {
      if (std::memcmp(type, "ftyp", 4) != 0 || payload_size < 8 ||
          std::memcmp(payload, "jxl ", 4) != 0) {
        return false;
      }
      first_box = false;
    }
    if (std::memcmp(type, "jxlc", 4) == 0) {
      if (saw_single || !fragments.empty()) return false;
      saw_single = true;
      single.assign(payload, payload + payload_size);
    } else if (std::memcmp(type, "jxlp", 4) == 0) {
      if (saw_single || payload_size <= 4) return false;
      const uint32_t index = ReadBE32(payload);
      fragments.emplace_back(index, std::vector<uint8_t>(payload + 4,
                                                          payload + payload_size));
    }
    offset += static_cast<size_t>(box_size);
    if (short_size == 0 && offset != input.size()) return false;
  }
  if (saw_single) {
    if (single.empty()) return false;
    *codestream = std::move(single);
    return true;
  }
  if (fragments.empty()) return false;
  bool final = false;
  for (size_t i = 0; i < fragments.size(); ++i) {
    const uint32_t index = fragments[i].first;
    if (final || (index & 0x7FFFFFFFu) != i) {
      return false;
    }
    final = (index & 0x80000000u) != 0;
    codestream->insert(codestream->end(), fragments[i].second.begin(),
                       fragments[i].second.end());
  }
  return final && !codestream->empty();
}

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
  if (frame->metadata.m.color_encoding.IsGray()) {
    JXL_RETURN_IF_ERROR(
        frame->state->output_encoding_info.SetFromMetadata(frame->metadata));
  }
  jxl::ImageBundle image(&manager, &frame->metadata.m);
  JXL_RETURN_IF_ERROR(jxl::DecodeFrame(frame->state.get(), nullptr, bytes.data()+offset, bytes.size()-offset, &frame->header, &image, frame->metadata));
  // These dump categories describe the single-pass DCT8 pixel path.
  return frame->header.encoding == jxl::FrameEncoding::kVarDCT && frame->header.passes.num_passes == 1 && frame->state->used_acs == 1;
}
}
bool DecodeFirstFrame(const std::vector<uint8_t>& codestream, DecodedFrame* frame) {
  std::vector<uint8_t> extracted;
  if (ExtractCodestream(codestream, &extracted) && Decode(extracted, frame))
    return true;
  std::fprintf(stderr, "dump: invalid or unsupported first frame\n"); return false;
}
}  // namespace harness
