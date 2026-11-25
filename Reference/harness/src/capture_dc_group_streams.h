#ifndef JXL_HARNESS_CAPTURE_DC_GROUP_STREAMS_H_
#define JXL_HARNESS_CAPTURE_DC_GROUP_STREAMS_H_

#include <cstdint>
#include <vector>

#include "decoded_frame.h"

namespace harness {

// One DC group section's two modular streams. `local` is false when a stream
// uses the frame's global tree, in which case the rest of it is empty.
struct LocalModularStream {
  bool local = false;
  size_t tree_node_count = 0;
  // Seven integers per node, as CaptureModularTree dumps them.
  std::vector<int64_t> tree_nodes;
  size_t histogram_count = 0;
};

struct DCGroupStreams {
  LocalModularStream dc;
  LocalModularStream metadata;
};

// Reads every DC group section's streams by decoding the section bytes the
// way ModularFrameDecoder does. Returns false if a section does not parse.
bool CaptureDCGroupStreams(const DecodedFrame &frame,
                           std::vector<DCGroupStreams> *groups);

} // namespace harness

#endif // JXL_HARNESS_CAPTURE_DC_GROUP_STREAMS_H_
