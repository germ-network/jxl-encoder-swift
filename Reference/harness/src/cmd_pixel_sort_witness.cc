#include <algorithm>
#include <fstream>
#include <numeric>
#include <string>
#include <vector>

#include "registry.h"

namespace harness {
namespace {

int RunPixelSortWitness(const std::vector<std::string> &args) {
  if (args.size() != 2)
    return 2;
  std::ofstream equalOutput(args[0]);
  std::ofstream nonuniformOutput(args[1]);
  for (size_t length = 3; length <= 26; ++length) {
    std::vector<int> counts(length, 0);
    std::vector<int> clusters(length);
    std::iota(clusters.begin(), clusters.end(), 0);
    std::sort(clusters.begin(), clusters.end(),
              [&](int a, int b) { return counts[a] > counts[b]; });
    equalOutput << length;
    for (int index : clusters)
      equalOutput << ' ' << index;
    equalOutput << '\n';
  }
  for (size_t length = 3; length <= 26; ++length) {
    std::vector<int> counts(length);
    std::vector<int> clusters(length);
    std::iota(clusters.begin(), clusters.end(), 0);
    nonuniformOutput << length << '\t';
    for (size_t i = 0; i < length; ++i) {
      counts[i] = static_cast<int>((i * 17 + length * 11) % 7);
      if (i != 0)
        nonuniformOutput << ',';
      nonuniformOutput << counts[i];
    }
    std::sort(clusters.begin(), clusters.end(),
              [&](int a, int b) { return counts[a] > counts[b]; });
    nonuniformOutput << '\t';
    for (size_t i = 0; i < clusters.size(); ++i) {
      if (i != 0)
        nonuniformOutput << ',';
      nonuniformOutput << clusters[i];
    }
    nonuniformOutput << '\n';
  }
  return equalOutput && nonuniformOutput ? 0 : 1;
}

const RegisterSubcommand kRegister({"pixel-sort-witness",
                                    "<equal.tsv> <nonuniform.tsv>",
                                    RunPixelSortWitness});

} // namespace
} // namespace harness
