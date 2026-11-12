// Self-registering subcommands and dump categories. A new one is a new .cc
// file holding a static Register* object; nothing shared is edited.
#ifndef JXL_HARNESS_REGISTRY_H_
#define JXL_HARNESS_REGISTRY_H_

#include <string>
#include <vector>

#include "semantic_dump.h"

namespace harness {

struct Subcommand {
  const char* name;
  const char* usage;
  int (*run)(const std::vector<std::string>& args);
};

const std::vector<Subcommand>& Subcommands();

struct RegisterSubcommand {
  explicit RegisterSubcommand(Subcommand command);
};

struct DecodedFrame;

// One category of the decoder-side semantic dump. `dump` records only fields
// named `<name>.…`; Reference/semantic-dump.md lists each category's fields.
struct DumpCategory {
  const char* name;
  void (*dump)(const DecodedFrame& frame, SemanticDumpWriter& out);
};

// In name order, so the dump's field order never depends on link order.
std::vector<DumpCategory> DumpCategories();

struct RegisterDumpCategory {
  explicit RegisterDumpCategory(DumpCategory category);
};

}  // namespace harness

#endif  // JXL_HARNESS_REGISTRY_H_
