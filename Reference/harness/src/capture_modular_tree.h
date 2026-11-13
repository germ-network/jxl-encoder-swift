#ifndef JXL_HARNESS_CAPTURE_MODULAR_TREE_H_
#define JXL_HARNESS_CAPTURE_MODULAR_TREE_H_

#include "lib/jxl/modular/encoding/dec_ma.h"

namespace jxl {
class FrameDecoder;
}

namespace harness {

jxl::Tree CaptureModularTree(const jxl::FrameDecoder &decoder);

} // namespace harness

#endif // JXL_HARNESS_CAPTURE_MODULAR_TREE_H_
