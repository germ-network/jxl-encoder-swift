// dump <in.jxl> [category…]: decodes a bare codestream with the pinned libjxl
// and writes the semantic dump of every registered category (or the named
// ones) to stdout. Works on cjxl's and this package's output alike.
#include <cstdio>

#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

int RunDump(const std::vector<std::string>& args) {
  std::fprintf(stderr, "dump: unimplemented\n");
  return 1;
}

const RegisterSubcommand kRegister(
    {"dump", "<in.jxl> [category…]", RunDump});

}  // namespace
}  // namespace harness
