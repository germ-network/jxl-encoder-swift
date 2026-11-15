#include <algorithm>
#include <fstream>
#include <numeric>
#include <string>
#include <vector>

#include "registry.h"

namespace harness {
namespace {

int RunPixelSortWitness(const std::vector<std::string>& args) {
  if (args.size() != 1) return 2;
  std::ofstream output(args[0]);
  for (size_t length = 3; length <= 26; ++length) {
    std::vector<int> counts(length, 0);
    std::vector<int> clusters(length);
    std::iota(clusters.begin(), clusters.end(), 0);
    std::sort(clusters.begin(), clusters.end(), [&](int a, int b) {
      return counts[a] > counts[b];
    });
    output << length;
    for (int index : clusters) output << ' ' << index;
    output << '\n';
  }
  return output ? 0 : 1;
}

const RegisterSubcommand kRegister({"pixel-sort-witness", "<out.tsv>",
                                    RunPixelSortWitness});

}  // namespace
}  // namespace harness
