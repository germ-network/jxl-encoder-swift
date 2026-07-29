// Emits the AC context model exhaustively as a binary fixture, so the Swift
// port is compared over the whole domain rather than at hand-picked points.
#include <stdio.h>
#include <stdint.h>
#include <vector>
#include "encoder/ac_context.h"
using namespace jxl;

int main(int argc, char** argv) {
  std::vector<uint32_t> out;
  // header: counts so the reader can slice without hardcoding
  out.push_back(256); out.push_back(4);    // nonZeroContext domain
  out.push_back(64);  out.push_back(64);   // zeroDensityContext domain
  for (uint32_t nz = 0; nz < 256; ++nz)
    for (uint32_t bc = 0; bc < 4; ++bc) out.push_back(NonZeroContext(nz, bc));
  for (uint32_t nzl = 0; nzl < 64; ++nzl)
    for (uint32_t k = 0; k < 64; ++k)
      for (uint32_t prev = 0; prev < 2; ++prev)
        out.push_back(ZeroDensityContext(nzl, k, 1, 0, prev));
  for (uint32_t c = 0; c < 3; ++c)
    for (uint32_t sc = 0; sc < kNumAcStrategyCodes; ++sc)
      out.push_back(BlockContext(c, sc));
  FILE* f = fopen(argv[1], "wb");
  fwrite(out.data(), sizeof(uint32_t), out.size(), f);
  fclose(f);
  fprintf(stderr, "wrote %zu u32 -> %s\n", out.size(), argv[1]);
  return 0;
}
