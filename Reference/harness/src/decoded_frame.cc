#include "decoded_frame.h"

#include <cstdio>

#include "lib/jxl/dec_frame.h"

namespace harness {

bool DecodeFirstFrame(const std::vector<uint8_t>& codestream,
                      DecodedFrame* frame) {
  std::fprintf(stderr, "DecodeFirstFrame: unimplemented\n");
  return false;
}

}  // namespace harness
