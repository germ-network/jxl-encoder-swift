// Dumps the bytes libjxl-tiny emits for the static DC and AC prefix codes.
#include <stdio.h>
#include <stdint.h>
#include "encoder/enc_bit_writer.h"
#include "encoder/enc_entropy_code.h"
#include "encoder/static_entropy_codes.h"

using namespace jxl;

static void emit(const char* label, BitWriter& w) {
  size_t bits = w.BitsWritten();
  {
    BitWriter::Allotment a(&w, 8);
    w.ZeroPadToByte();
    a.Reclaim(&w);
  }
  auto span = w.GetSpan();
  printf("%s %zu %zu", label, bits, span.size());
  for (size_t i = 0; i < span.size(); ++i) printf(" %02x", span.data()[i]);
  printf("\n");
}

int main() {
  // full prefix-code sets, as WriteDCGlobal / WriteACGlobal emit them
  printf("CODES\n");
  {
    BitWriter w;
    WritePrefixCodesForTest(kDCPrefixCodes, kNumDCPrefixCodes, &w);
    emit("DC", w);
  }
  {
    BitWriter w;
    WritePrefixCodesForTest(kACPrefixCodes, kNumACPrefixCodes, &w);
    emit("AC", w);
  }
  // each code individually, so a mismatch localises
  for (size_t c = 0; c < kNumDCPrefixCodes; ++c) {
    BitWriter w;
    BitWriter::Allotment a(&w, 4096);
    WritePrefixCodeForTest(kDCPrefixCodes[c], &w);
    a.Reclaim(&w);
    char label[32];
    snprintf(label, sizeof(label), "DC%zu", c);
    emit(label, w);
  }
  for (size_t c = 0; c < kNumACPrefixCodes; ++c) {
    BitWriter w;
    BitWriter::Allotment a(&w, 4096);
    WritePrefixCodeForTest(kACPrefixCodes[c], &w);
    a.Reclaim(&w);
    char label[32];
    snprintf(label, sizeof(label), "AC%zu", c);
    emit(label, w);
  }
  return 0;
}
