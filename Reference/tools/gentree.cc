// Reference bytes for WriteContextTree (across DC group counts) and for
// WriteEntropyCode on the static DC/AC codes. Pins the clustering, context-map
// coding and entropy-code serialization.
#include <stdio.h>
#include <vector>

#include "encoder/enc_bit_writer.h"
#include "encoder/enc_entropy_code.h"
#include "encoder/enc_frame.h"
#include "encoder/static_entropy_codes.h"

using namespace jxl;

static void emit(const char* label, BitWriter& w) {
  size_t bits = w.BitsWritten();
  { BitWriter::Allotment a(&w, 8); w.ZeroPadToByte(); a.Reclaim(&w); }
  auto span = w.GetSpan();
  printf("%s %zu %zu", label, bits, span.size());
  for (size_t i = 0; i < span.size(); ++i) printf(" %02x", span.data()[i]);
  printf("\n");
}

int main() {
  for (size_t n : {1u, 2u, 3u, 7u, 16u, 100u}) {
    BitWriter w;
    WriteContextTreeForTest(n, &w);
    char label[32];
    snprintf(label, sizeof(label), "TREE%zu", n);
    emit(label, w);
  }
  {
    BitWriter w;
    EntropyCode dc(kDCContextMap, sizeof(kDCContextMap), kDCPrefixCodes,
                   kNumDCPrefixCodes);
    WriteEntropyCode(dc, &w);
    emit("ECDC", w);
  }
  {
    BitWriter w;
    EntropyCode ac(kACContextMap, sizeof(kACContextMap), kACPrefixCodes,
                   kNumACPrefixCodes);
    WriteEntropyCode(ac, &w);
    emit("ECAC", w);
  }
  return 0;
}
