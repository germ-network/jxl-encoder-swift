// Writer for the planar float32 "DUM0" stage format that
// Tests/JXLEncoderTests/StageDump.swift reads: 16-byte little-endian header
// (magic 0x304D5544, xsize, ysize, channels), then channel-major planes.
#ifndef JXL_HARNESS_STAGE_DUMP_H_
#define JXL_HARNESS_STAGE_DUMP_H_

#include <string>

#include "lib/jxl/image.h"

namespace harness {

bool WriteStageDump(const std::string& path, const jxl::Image3F& image);
bool ReadStageDump(const std::string& path, jxl::Image3F* image);

}  // namespace harness

#endif  // JXL_HARNESS_STAGE_DUMP_H_
