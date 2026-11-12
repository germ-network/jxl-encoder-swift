#include "registry.h"

#include <algorithm>
#include <cstring>

namespace harness {
namespace {

// Function-local statics: registration runs during static initialization, in
// unspecified order across files.
std::vector<Subcommand>& MutableSubcommands() {
  static std::vector<Subcommand> commands;
  return commands;
}

std::vector<DumpCategory>& MutableDumpCategories() {
  static std::vector<DumpCategory> categories;
  return categories;
}

}  // namespace

const std::vector<Subcommand>& Subcommands() { return MutableSubcommands(); }

RegisterSubcommand::RegisterSubcommand(Subcommand command) {
  MutableSubcommands().push_back(command);
}

std::vector<DumpCategory> DumpCategories() {
  std::vector<DumpCategory> sorted = MutableDumpCategories();
  std::sort(sorted.begin(), sorted.end(),
            [](const DumpCategory& a, const DumpCategory& b) {
              return std::strcmp(a.name, b.name) < 0;
            });
  return sorted;
}

RegisterDumpCategory::RegisterDumpCategory(DumpCategory category) {
  MutableDumpCategories().push_back(category);
}

}  // namespace harness
