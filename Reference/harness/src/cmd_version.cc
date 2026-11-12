// version: the pinned libjxl commit this harness was built from and the
// Highway target dynamic dispatch selects at run time. Generators record both
// in provenance.tsv's config column.
#include <cstdio>

#include "hwy/targets.h"
#include "hwy/per_target.h"
#include "registry.h"

namespace harness {
namespace {

int RunVersion(const std::vector<std::string>& args) {
  if (!args.empty()) return 2;
  std::printf("libjxl=%s\nhwy=%s\n", LIBJXL_COMMIT, hwy::TargetName(hwy::DispatchedTarget()));
  return 0;
}

const RegisterSubcommand kRegister({"version", "", RunVersion});

}  // namespace
}  // namespace harness
