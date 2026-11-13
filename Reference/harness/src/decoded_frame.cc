#include "decoded_frame.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include "lib/jxl/dec_frame.h"
#include "lib/jxl/base/bits.h"
#include "lib/jxl/headers.h"
#include "lib/jxl/icc_codec.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/toc.h"
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
  std::sort(fragments.begin(), fragments.end(), [](const auto& left,
                                                    const auto& right) {
    return (left.first & 0x7FFFFFFFu) < (right.first & 0x7FFFFFFFu);
  });
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
  jxl::FrameDecoder decoder(frame->state.get(), frame->metadata, nullptr,
                            /*use_slow_rendering_pipeline=*/false);
  jxl::BitReader reader(
      jxl::Bytes(bytes.data() + offset, bytes.size() - offset));
  jxl::Status frame_reader_closed = true;
  size_t header_bytes = 0;
  jxl::Status frame_header_result = [&]() -> jxl::Status {
    jxl::BitReaderScopedCloser closer(reader, frame_reader_closed);
    JXL_RETURN_IF_ERROR(
        decoder.InitFrame(&reader, &image, /*is_preview=*/false));
    JXL_RETURN_IF_ERROR(decoder.InitFrameOutput());
    frame->header = decoder.GetFrameHeader();
    JXL_RETURN_IF_ERROR(reader.AllReadsWithinBounds());
    header_bytes = reader.TotalBitsConsumed() / jxl::kBitsPerByte;
    return true;
  }();
  JXL_RETURN_IF_ERROR(frame_reader_closed);
  JXL_RETURN_IF_ERROR(frame_header_result);

  auto &layout = frame->entropy_layout;
  const jxl::FrameDimensions dimensions = frame->header.ToFrameDimensions();
  layout.groups_x = dimensions.xsize_groups;
  layout.groups_y = dimensions.ysize_groups;
  layout.num_groups = dimensions.num_groups;
  layout.num_dc_groups = dimensions.num_dc_groups;
  layout.num_passes = frame->header.passes.num_passes;
  size_t position = header_bytes;
  jxl::Status section_result = [&]() -> jxl::Status {
    std::vector<std::unique_ptr<jxl::BitReader>> section_readers;
    std::vector<std::unique_ptr<jxl::BitReaderScopedCloser>> section_closers;
    std::vector<jxl::FrameDecoder::SectionInfo> section_info;
    std::vector<jxl::FrameDecoder::SectionStatus> section_status;
    const auto &toc = decoder.Toc();
    section_readers.reserve(toc.size());
    section_closers.reserve(toc.size());
    section_info.reserve(toc.size());
    for (size_t index = 0; index < toc.size(); ++index) {
      const auto &entry = toc[index];
      if (position > bytes.size() - offset ||
          entry.size > bytes.size() - offset - position)
        return false;
      layout.sections.push_back(
          LayoutSection{entry.id, index, offset + position, entry.size});
      auto section_reader = jxl::make_unique<jxl::BitReader>(
          jxl::Bytes(bytes.data() + offset + position, entry.size));
      section_closers.emplace_back(jxl::make_unique<jxl::BitReaderScopedCloser>(
          *section_reader, closed));
      section_info.emplace_back(jxl::FrameDecoder::SectionInfo{
          section_reader.get(), entry.id, index});
      section_readers.emplace_back(std::move(section_reader));
      position += entry.size;
    }
    section_status.resize(section_info.size());
    JXL_RETURN_IF_ERROR(decoder.ProcessSections(
        section_info.data(), section_info.size(), section_status.data()));
    for (auto status : section_status) {
      JXL_RETURN_IF_ERROR(status == jxl::FrameDecoder::kDone);
    }
    return true;
  }();
  JXL_RETURN_IF_ERROR(closed);
  JXL_RETURN_IF_ERROR(section_result);
  JXL_RETURN_IF_ERROR(decoder.FinalizeFrame());
  layout.num_histograms = frame->state->shared->num_histograms;
  layout.selector_bits = jxl::CeilLog2Nonzero(layout.num_histograms);
  const size_t first_ac_id = 2 + layout.num_dc_groups;
  for (const auto &section : layout.sections) {
    if (section.id < first_ac_id)
      continue;
    const size_t ac_id = section.id - first_ac_id;
    const size_t pass = ac_id / layout.num_groups;
    const size_t group = ac_id % layout.num_groups;
    if (pass >= layout.num_passes)
      return false;
    jxl::BitReader selector_reader(
        jxl::Bytes(bytes.data() + section.offset, section.size));
    const size_t value = layout.selector_bits == 0
                             ? 0
                             : selector_reader.ReadBits(layout.selector_bits);
    const bool in_bounds = selector_reader.AllReadsWithinBounds();
    const bool selector_closed = selector_reader.Close();
    JXL_RETURN_IF_ERROR(in_bounds);
    JXL_RETURN_IF_ERROR(selector_closed);
    layout.selectors.push_back(LayoutSelector{pass, group, section.id, value});
  }
  // These dump categories describe the single-pass DCT8 pixel path.
  return frame->header.encoding == jxl::FrameEncoding::kVarDCT &&
         frame->header.passes.num_passes == 1 && frame->state->used_acs == 1;
}
}
bool DecodeFirstFrame(const std::vector<uint8_t>& codestream, DecodedFrame* frame) {
  std::vector<uint8_t> extracted;
  if (ExtractCodestream(codestream, &extracted) && Decode(extracted, frame))
    return true;
  std::fprintf(stderr, "dump: invalid or unsupported first frame\n"); return false;
}
}  // namespace harness
