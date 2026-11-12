// Fixed writer exercise for the harness checks; omitted from user help.
#include <cstdio>
#include "registry.h"
#include "decoded_frame.h"
#include "stage_dump.h"
#include "lib/jxl/memory_manager_internal.h"
namespace harness {
namespace {
jxl::Status QuantFieldSelftest(const std::string& path) {
  JxlMemoryManager manager; JXL_RETURN_IF_ERROR(jxl::MemoryManagerInit(&manager, nullptr));
  DecodedFrame frame; frame.state = std::make_unique<jxl::PassesDecoderState>(&manager);
  auto& field = frame.state->shared_storage.raw_quant_field;
  JXL_ASSIGN_OR_RETURN(field, jxl::ImageI::Create(&manager, 3, 2));
  for (size_t y = 0; y < 2; ++y) for (size_t x = 0; x < 3; ++x) field.Row(y)[x] = 10*y+x+1;
  SemanticDumpWriter writer;
  for (const auto& category : DumpCategories()) if (std::string(category.name) == "quant_field") category.dump(frame, writer);
  FILE* out = std::fopen(path.c_str(), "wb"); if (!out) return false;
  writer.Write(out); return std::fclose(out) == 0;
}
int RunSelftest(const std::vector<std::string>& args) {
  if (args.size() != 2) return 2;
  if (args[0] == "--quant-field") return QuantFieldSelftest(args[1]) ? 0 : 1;
  if (args[0] == "--read") { jxl::Image3F image; return ReadStageDump(args[1], &image) ? 0 : 1; }
  SemanticDumpWriter writer;
  writer.Floats("quant_field.test", {-0.0f, 1.2345678f, -2.0f, 0.0f});
  writer.Integers("frame.size", {3, 2});
  writer.Integers("coeff_order.test", {0, 1, 3, 2});
  FILE* out = std::fopen(args[0].c_str(), "wb"); if (!out) return 1;
  writer.Write(out); if (std::fclose(out)) return 1;
  JxlMemoryManager manager; if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::Image3F image;
  auto allocate = [&]() -> jxl::Status { JXL_ASSIGN_OR_RETURN(image, jxl::Image3F::Create(&manager, 3, 2)); return true; };
  if (!allocate()) return 1;
  for (size_t c = 0; c < 3; ++c) for (size_t y = 0; y < 2; ++y) for (size_t x = 0; x < 3; ++x) image.PlaneRow(c, y)[x] = static_cast<float>(6*c + 3*y + x) - 4;
  if (!WriteStageDump(args[1], image)) return 1;
  jxl::Image3F read; if (!ReadStageDump(args[1], &read)) return 1;
  if (read.xsize() != 3 || read.ysize() != 2) return 1;
  for (size_t c = 0; c < 3; ++c) for (size_t y = 0; y < 2; ++y) for (size_t x = 0; x < 3; ++x) if (read.PlaneRow(c, y)[x] != image.PlaneRow(c, y)[x]) return 1;
  return 0;
}
const RegisterSubcommand kRegister({"selftest", "", RunSelftest});
}
}  // namespace harness
