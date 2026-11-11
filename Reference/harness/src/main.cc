// jxl-harness <subcommand> [args…]: reference instrumentation for the pinned
// libjxl. Subcommands register themselves (registry.h).
#include <cstdio>
#include <string>
#include <vector>

#include "registry.h"

int main(int argc, char** argv) {
  const auto& commands = harness::Subcommands();
  if (argc >= 2) {
    for (const auto& command : commands) {
      if (command.name == std::string(argv[1])) {
        return command.run(std::vector<std::string>(argv + 2, argv + argc));
      }
    }
  }
  std::fprintf(stderr, "usage: jxl-harness <subcommand> [args…]\n");
  for (const auto& command : commands) {
    if (std::string(command.name) == "selftest") continue;
    std::fprintf(stderr, "  %s %s\n", command.name, command.usage);
  }
  return 2;
}
