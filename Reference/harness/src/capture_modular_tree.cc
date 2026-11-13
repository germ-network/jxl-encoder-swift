#include "capture_modular_tree.h"

#include "lib/jxl/dec_frame.h"
#include "lib/jxl/dec_modular.h"

namespace harness {

jxl::Tree CaptureModularTree(const jxl::FrameDecoder &decoder) {
  return decoder.modular_frame_decoder_.tree;
}

} // namespace harness
