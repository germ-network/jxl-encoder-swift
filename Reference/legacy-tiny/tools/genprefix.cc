// Dumps the bytes libjxl-tiny emits for the static DC and AC prefix codes,
// plus CreateHuffmanTree outputs for assorted histograms. Pins the port's
// prefix-code serialization and Huffman builder against the reference.
#include <stdio.h>
#include <stdint.h>
#include <vector>

#include "encoder/enc_bit_writer.h"
#include "encoder/enc_entropy_code.h"
#include "encoder/enc_huffman_tree.h"
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
  // CreateHuffmanTree over histograms that exercise the depth-limit retry
  printf("TREES\n");
  std::vector<std::vector<uint32_t>> histos = {
      {1, 1, 1, 1},
      {5, 0, 3, 0, 1},
      {100, 1, 1, 1, 1, 1, 1, 1},
      {1},
      {0, 0, 7},
      {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384},
  };
  for (size_t h = 0; h < histos.size(); ++h) {
    auto& counts = histos[h];
    std::vector<uint8_t> depth(counts.size(), 0);
    CreateHuffmanTree(counts.data(), counts.size(), 15, depth.data());
    printf("T%zu %zu", h, counts.size());
    for (size_t i = 0; i < depth.size(); ++i) printf(" %d", depth[i]);
    printf("\n");
  }

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
