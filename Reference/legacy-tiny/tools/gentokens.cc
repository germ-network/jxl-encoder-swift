// Prints reference outputs for the entropy primitives: hybrid-uint splitting,
// signed packing, the AC context functions, and the bytes WriteToken emits.
// Used to pin the Swift port against the reference rather than against a
// reading of the spec.
#include <stdio.h>

#include "encoder/ac_context.h"
#include "encoder/common.h"
#include "encoder/enc_bit_writer.h"
#include "encoder/enc_entropy_code.h"
#include "encoder/static_entropy_codes.h"
#include "encoder/token.h"

using namespace jxl;

int main() {
  printf("UINT\n");
  const uint32_t vals[] = {0, 1, 15, 16, 17, 20, 24, 28, 32, 63, 64,
                           255, 256, 1000, 65535, 65536, 1u << 20};
  for (uint32_t v : vals) {
    uint32_t tok, nbits, bits;
    UintCoder().Encode(v, &tok, &nbits, &bits);
    printf("%u %u %u %u\n", v, tok, nbits, bits);
  }

  printf("PACK\n");
  const int32_t svals[] = {0, 1, -1, 2, -2, 100, -100, 32767, -32768, 1 << 20, -(1 << 20)};
  for (int32_t v : svals) printf("%d %u\n", v, PackSigned(v));

  printf("NZCTX\n");
  for (int nz : {0, 1, 7, 8, 9, 20, 63, 64, 100}) {
    for (int bc = 0; bc < 4; ++bc) printf("%d %d %u\n", nz, bc, NonZeroContext(nz, bc));
  }

  printf("ZDCTX\n");
  for (int nzl : {1, 2, 5, 33, 63}) {
    for (int k : {1, 2, 8, 20, 63}) {
      for (int prev : {0, 1}) {
        printf("%d %d %d %zu\n", nzl, k, prev, ZeroDensityContext(nzl, k, 1, 0, prev));
      }
    }
  }

  printf("BLOCKCTX\n");
  for (int c = 0; c < 3; ++c)
    for (int sc : {0, 1, 6, 7, 26}) printf("%d %d %zu\n", c, sc, BlockContext(c, sc));

  printf("WRITETOKEN\n");
  {
    EntropyCode ac_code(kACContextMap, kNumACContexts, kACPrefixCodes,
                        kNumACPrefixCodes);
    struct TV { uint32_t ctx, val; };
    const TV tvs[] = {{0, 0}, {0, 1}, {0, 63}, {5, 7}, {100, 300},
                      {148, 1}, {700, 12}, {1979, 65535}};
    for (auto tv : tvs) {
      BitWriter w;
      BitWriter::Allotment a(&w, 1024);
      WriteToken(Token(tv.ctx, tv.val), ac_code, &w);
      size_t bits = w.BitsWritten();
      w.ZeroPadToByte();
      a.Reclaim(&w);
      auto span = w.GetSpan();
      printf("%u %u %zu", tv.ctx, tv.val, bits);
      for (size_t i = 0; i < span.size(); ++i) printf(" %02x", span.data()[i]);
      printf("\n");
    }
  }
  return 0;
}
