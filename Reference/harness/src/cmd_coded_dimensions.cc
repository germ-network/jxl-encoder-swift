#include <array>
#include <cstdio>
#include <vector>

#include "lib/jxl/frame_dimensions.h"
#include "registry.h"
#include "semantic_dump.h"

namespace harness {
namespace {

int RunCodedDimensions(const std::vector<std::string>& args) {
  if (args.size() != 1) return 2;
  constexpr std::array<size_t, 10> dimensions = {1, 7, 8, 9, 15, 16, 17, 255, 256, 257};
  SemanticDumpWriter dump;
  std::vector<int64_t> inputs;
  for (size_t dimension : dimensions) inputs.push_back(dimension);
  dump.Integers("coded_blocks.dimensions", inputs);
  std::vector<int64_t> widths;
  std::vector<int64_t> heights;
  std::array<std::vector<int64_t>, 4> block_widths;
  std::array<std::vector<int64_t>, 4> block_heights;
  for (size_t width : dimensions) {
    for (size_t height : dimensions) {
      widths.push_back(width);
      heights.push_back(height);
      for (size_t hshift = 0; hshift <= 1; ++hshift) {
        for (size_t vshift = 0; vshift <= 1; ++vshift) {
          jxl::FrameDimensions frame;
          frame.Set(width, height, 0, hshift, vshift, false, 1);
          block_widths[hshift * 2 + vshift].push_back(
              static_cast<int64_t>(frame.xsize_blocks));
          block_heights[hshift * 2 + vshift].push_back(
              static_cast<int64_t>(frame.ysize_blocks));
        }
      }
    }
  }
  dump.Integers("coded_blocks.widths", widths);
  dump.Integers("coded_blocks.heights", heights);
  for (size_t hshift = 0; hshift <= 1; ++hshift) {
    for (size_t vshift = 0; vshift <= 1; ++vshift) {
      const std::string suffix = "h" + std::to_string(hshift) + "v" +
                                 std::to_string(vshift);
      dump.Integers("coded_blocks.width_blocks." + suffix,
                    block_widths[hshift * 2 + vshift]);
      dump.Integers("coded_blocks.height_blocks." + suffix,
                    block_heights[hshift * 2 + vshift]);
    }
  }
  FILE* file = std::fopen(args[0].c_str(), "w");
  if (file == nullptr) return 1;
  dump.Write(file);
  return std::fclose(file) == 0 ? 0 : 1;
}

const RegisterSubcommand kRegister(
    {"coded-dimensions", "<out.sem>", RunCodedDimensions});

}  // namespace
}  // namespace harness
