#include <cstdio>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "jxl/encode.h"
#include "jxl/thread_parallel_runner.h"
#include "registry.h"

namespace harness {
namespace {

bool ReadBytes(const std::string& path, std::vector<uint8_t>* bytes) {
  std::ifstream input(path, std::ios::binary);
  if (!input) return false;
  bytes->assign(std::istreambuf_iterator<char>(input), {});
  return !input.bad() && !bytes->empty();
}

bool EncodeJPEG(const std::vector<std::string>& args) {
  if (args.size() != 2) return false;
  std::vector<uint8_t> jpeg;
  if (!ReadBytes(args[0], &jpeg)) return false;

  std::unique_ptr<JxlEncoder, decltype(&JxlEncoderDestroy)> encoder(
      JxlEncoderCreate(nullptr), JxlEncoderDestroy);
  if (!encoder || JxlEncoderStoreJPEGMetadata(encoder.get(), JXL_TRUE) !=
                      JXL_ENC_SUCCESS) {
    return false;
  }
  std::unique_ptr<void, decltype(&JxlThreadParallelRunnerDestroy)> runner(
      JxlThreadParallelRunnerCreate(nullptr, 1), JxlThreadParallelRunnerDestroy);
  if (!runner ||
      JxlEncoderSetParallelRunner(encoder.get(), JxlThreadParallelRunner,
                                  runner.get()) != JXL_ENC_SUCCESS) {
    return false;
  }
  auto* settings = JxlEncoderFrameSettingsCreate(encoder.get(), nullptr);
  if (!settings ||
      JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT,
                                       4) != JXL_ENC_SUCCESS ||
      JxlEncoderAddJPEGFrame(settings, jpeg.data(), jpeg.size()) !=
          JXL_ENC_SUCCESS) {
    return false;
  }
  JxlEncoderCloseInput(encoder.get());

  std::vector<uint8_t> output(65536);
  size_t used = 0;
  for (;;) {
    uint8_t* next = output.data() + used;
    size_t available = output.size() - used;
    const auto status = JxlEncoderProcessOutput(encoder.get(), &next, &available);
    used = output.size() - available;
    if (status == JXL_ENC_SUCCESS) break;
    if (status != JXL_ENC_NEED_MORE_OUTPUT) return false;
    output.resize(output.size() * 2);
  }

  const std::string temporary = args[1] + ".tmp";
  std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
  if (!file) return false;
  file.write(reinterpret_cast<const char*>(output.data()), used);
  file.close();
  if (file.fail() || std::rename(temporary.c_str(), args[1].c_str()) != 0) {
    std::remove(temporary.c_str());
    return false;
  }
  return true;
}

int RunEncodeJPEG(const std::vector<std::string>& args) {
  if (args.size() != 2) return 2;
  if (EncodeJPEG(args)) return 0;
  std::fprintf(stderr, "encode-jpeg: invalid JPEG or encoding/output failed\n");
  return 1;
}

const RegisterSubcommand kRegister(
    {"encode-jpeg", "<in.jpg> <out.jxl>", RunEncodeJPEG});

}  // namespace
}  // namespace harness
