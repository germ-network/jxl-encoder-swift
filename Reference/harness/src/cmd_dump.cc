// Registered categories operate on one retained, fully decoded frame.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <set>
#include "decoded_frame.h"
#include "registry.h"
namespace harness {
namespace {
int RunDump(const std::vector<std::string>& args) {
  if (args.empty()) return 2;
  std::ifstream in(args[0], std::ios::binary);
  if (!in) return 1;
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), {});
  DecodedFrame frame;
  if (!DecodeFirstFrame(bytes, &frame)) return 1;
  auto categories = DumpCategories();
  std::set<std::string> wanted(args.begin()+1, args.end());
  for (const auto& name : wanted) {
    bool found = false; for (const auto& category : categories) if (name == category.name) found = true;
    if (!found) { std::fprintf(stderr, "dump: unknown category %s\n", name.c_str()); return 2; }
  }
  SemanticDumpWriter out;
  for (const auto& category : categories) if (wanted.empty() || wanted.count(category.name)) category.dump(frame, out);
  out.Write(stdout); return std::ferror(stdout) ? 1 : 0;
}
const RegisterSubcommand kRegister({"dump", "<in.jxl> [category…]", RunDump});
}
}  // namespace harness
