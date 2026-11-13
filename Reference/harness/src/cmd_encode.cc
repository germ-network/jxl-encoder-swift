// Public encoder API, with explicit pixel format, transfer function and e4 settings.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include "jxl/encode.h"
#include "registry.h"
#include "stage_dump.h"
namespace harness {
namespace {
bool Encode(const std::vector<std::string>& args) {
  char* end = nullptr;
  float distance = std::strtof(args[1].c_str(), &end);
  if (end == args[1].c_str() || *end || !std::isfinite(distance) || distance <= 0) return false;
  int output_mode = 0;
  if (args.size() >= 4) {
    long parsed = std::strtol(args[3].c_str(), &end, 10);
    if (end == args[3].c_str() || *end || parsed < 0 || parsed > 2) return false;
    output_mode = static_cast<int>(parsed);
  }
  if (args.size() == 5) {
    long parsed = std::strtol(args[4].c_str(), &end, 10);
    if (end == args[4].c_str() || *end || parsed != 0) return false;
  }
  const bool linear = args[0].size() >= 5 && args[0].substr(args[0].size()-5) == ".dump";
  uint32_t width, height;
  std::vector<float> floats;
  std::vector<uint8_t> bytes;
  if (linear) {
    jxl::Image3F image;
    if (!ReadStageDump(args[0], &image)) return false;
    width = image.xsize(); height = image.ysize();
    floats.resize(static_cast<size_t>(width) * height * 3);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) for (size_t c = 0; c < 3; ++c) floats[(y * width + x)*3+c] = image.PlaneRow(c,y)[x];
  } else {
    std::ifstream in(args[0], std::ios::binary);
    auto token = [&]() { std::string value; while (in >> std::ws && in.peek() == '#') { std::getline(in,value); } in >> value; return value; };
    if (token() != "P6") return false;
    try { width = std::stoul(token()); height = std::stoul(token()); } catch (...) { return false; }
    if (token() != "255" || width == 0 || height == 0) return false;
    int separator = in.get();
    if (separator == '\r' && in.peek() == '\n') in.get();
    else if (separator != '\n' && separator != ' ' && separator != '\t') return false;
    bytes.resize(static_cast<size_t>(width) * height * 3);
    in.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
    if (static_cast<size_t>(in.gcount()) != bytes.size() || in.peek() != EOF) return false;
  }
  std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> enc(JxlEncoderCreate(nullptr), JxlEncoderDestroy);
  if (!enc || JxlEncoderUseContainer(enc.get(), output_mode == 2 ? JXL_TRUE : JXL_FALSE) != JXL_ENC_SUCCESS) return false;
  JxlBasicInfo info; JxlEncoderInitBasicInfo(&info);
  info.xsize = width; info.ysize = height; info.num_color_channels = 3;
  info.bits_per_sample = linear ? 32 : 8; info.exponent_bits_per_sample = linear ? 8 : 0;
  info.intensity_target = 255;
  if (JxlEncoderSetBasicInfo(enc.get(), &info) != JXL_ENC_SUCCESS) return false;
  JxlColorEncoding color;
  if (linear) JxlColorEncodingSetToLinearSRGB(&color, JXL_FALSE); else JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
  if (JxlEncoderSetColorEncoding(enc.get(), &color) != JXL_ENC_SUCCESS) return false;
  auto* settings = JxlEncoderFrameSettingsCreate(enc.get(), nullptr);
  if (JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 4) != JXL_ENC_SUCCESS ||
      JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_OUTPUT_MODE, output_mode) != JXL_ENC_SUCCESS ||
      (args.size() == 5 && JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_BUFFERING, 0) != JXL_ENC_SUCCESS) ||
      JxlEncoderSetFrameDistance(settings, distance) != JXL_ENC_SUCCESS) return false;
  JxlPixelFormat format{3, linear ? JXL_TYPE_FLOAT : JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  const void* pixels = linear ? static_cast<const void*>(floats.data()) : bytes.data();
  const size_t size = linear ? floats.size()*sizeof(float) : bytes.size();
  if (JxlEncoderAddImageFrame(settings, &format, pixels, size) != JXL_ENC_SUCCESS) return false;
  JxlEncoderCloseInput(enc.get());
  std::vector<uint8_t> output(65536); size_t used = 0;
  for (;;) {
    uint8_t* next = output.data()+used; size_t available = output.size()-used;
    auto status = JxlEncoderProcessOutput(enc.get(), &next, &available);
    used = output.size()-available;
    if (status == JXL_ENC_SUCCESS) break;
    if (status != JXL_ENC_NEED_MORE_OUTPUT) return false;
    output.resize(output.size()*2);
  }
  std::ofstream out(args[2], std::ios::binary); out.write(reinterpret_cast<const char*>(output.data()), used); out.close(); return !out.fail();
}
int RunEncode(const std::vector<std::string>& args) {
  if (args.size() < 3 || args.size() > 5) return 2;
  if (Encode(args)) return 0;
  std::fprintf(stderr, "encode: invalid input or encoding failed\n"); return 1;
}
const RegisterSubcommand kRegister({"encode", "<in.ppm|in.dump> <distance> <out.jxl> [output_mode 0..2 [buffering=0]]", RunEncode});
}
}  // namespace harness
