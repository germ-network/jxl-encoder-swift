// A codestream's first frame decoded by the pinned libjxl, with the decoder
// state the dump categories read. Only public members of libjxl's internal
// headers are used; see Reference/semantic-dump.md for what is not retained.
#ifndef JXL_HARNESS_DECODED_FRAME_H_
#define JXL_HARNESS_DECODED_FRAME_H_

#include <cstdint>
#include <memory>
#include <vector>

#include "lib/jxl/dec_cache.h"
#include "lib/jxl/frame_header.h"
#include "lib/jxl/image_metadata.h"

namespace harness {

struct DecodedFrame {
  jxl::CodecMetadata metadata;
  jxl::FrameHeader header{&metadata};
  std::unique_ptr<jxl::PassesDecoderState> state;
};

// Decodes the bare codestream's first frame. Returns false with a message on
// stderr if it doesn't decode.
bool DecodeFirstFrame(const std::vector<uint8_t>& codestream, DecodedFrame* frame);

}  // namespace harness

#endif  // JXL_HARNESS_DECODED_FRAME_H_
