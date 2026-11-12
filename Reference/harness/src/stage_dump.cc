#include "stage_dump.h"
#include <cstring>
#include <fstream>
#include <limits>
#include "lib/jxl/memory_manager_internal.h"
namespace harness {
namespace {
void Write32(std::ostream& out, uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) out.put(static_cast<char>(value >> shift));
}
bool Read32(std::istream& in, uint32_t* value) {
  *value = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    int byte = in.get(); if (byte == EOF) return false;
    *value |= static_cast<uint32_t>(byte) << shift;
  }
  return true;
}
}
bool WriteStageDump(const std::string& path, const jxl::Image3F& image) {
  std::ofstream out(path, std::ios::binary);
  Write32(out, 0x304D5544); Write32(out, image.xsize()); Write32(out, image.ysize()); Write32(out, 3);
  for (size_t c = 0; c < 3; ++c) for (size_t y = 0; y < image.ysize(); ++y) for (size_t x = 0; x < image.xsize(); ++x) {
    uint32_t bits; float value = image.PlaneRow(c, y)[x];
    static_assert(sizeof(value) == sizeof(bits)); std::memcpy(&bits, &value, sizeof(bits)); Write32(out, bits);
  }
  out.close(); return !out.fail();
}
bool ReadStageDump(const std::string& path, jxl::Image3F* image) {
  std::ifstream in(path, std::ios::binary | std::ios::ate);
  const auto length = in.tellg(); in.seekg(0);
  uint32_t magic, xs, ys, channels;
  if (!Read32(in, &magic) || !Read32(in, &xs) || !Read32(in, &ys) || !Read32(in, &channels) || magic != 0x304D5544 || channels != 3 || xs == 0 || ys == 0) return false;
  const uint64_t pixels = static_cast<uint64_t>(xs) * ys;
  if (pixels > (std::numeric_limits<uint64_t>::max() - 16) / 12 || static_cast<uint64_t>(length) != 16 + pixels * 12) return false;
  // The image's allocator must outlive any caller that retains the image.
  static JxlMemoryManager manager = [] { JxlMemoryManager m; jxl::MemoryManagerInit(&m, nullptr); return m; }();
  JXL_ASSIGN_OR_RETURN(*image, jxl::Image3F::Create(&manager, xs, ys));
  for (size_t c = 0; c < 3; ++c) for (size_t y = 0; y < ys; ++y) for (size_t x = 0; x < xs; ++x) {
    uint32_t bits; if (!Read32(in, &bits)) return false;
    std::memcpy(&image->PlaneRow(c, y)[x], &bits, sizeof(bits));
  }
  return true;
}
}  // namespace harness
