// version: the pinned libjxl commit this harness was built from and the
// Highway target dynamic dispatch selects at run time. Generators record both
// in provenance.tsv's config column.
#include <cstdio>

#include "hwy/targets.h"
#include "registry.h"

namespace harness {
namespace {

int RunVersion(const std::vector<std::string>& args) {
  std::fprintf(stderr, "version: unimplemented\n");
  return 1;
}

const RegisterSubcommand kRegister({"version", "", RunVersion});

}  // namespace
}  // namespace harness
