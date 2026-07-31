// TOOL (jxl-encoder-swift): dumps the bits libjxl writes for a RAW quantization
// matrix, so the Swift port's `QuantMatrixWriter` can be diffed against it.
// libjxl-tiny has no JPEG path, so this is the only reference for that stage.
#include <jxl/memory_manager.h>

#include <cstdio>
#include <vector>

#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_bit_writer.h"
#include "lib/jxl/enc_modular.h"
#include "lib/jxl/enc_quant_weights.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/quant_weights.h"

int main(int argc, char** argv) {
  using namespace jxl;
  // The default allocator; MemoryManagerInit accepts null and fills it in.
  JxlMemoryManager manager;
  if (!MemoryManagerInit(&manager, nullptr)) {
    fprintf(stderr, "MemoryManagerInit failed\n");
    return 1;
  }
  JxlMemoryManager* memory_manager = &manager;

  // A table with distinct, asymmetric values so any ordering error shows.
  std::vector<int> qt(kDCTBlockSize * 3);
  for (size_t c = 0; c < 3; c++) {
    for (size_t i = 0; i < kDCTBlockSize; i++) {
      qt[c * kDCTBlockSize + i] = static_cast<int>(1 + c * 64 + i);
    }
  }
  // Echo the table so the Swift side can feed the identical input.
  fprintf(stderr, "TABLE");
  for (size_t i = 0; i < qt.size(); i++) fprintf(stderr, " %d", qt[i]);
  fprintf(stderr, "\n");

  QuantEncoding encoding = QuantEncoding::RAW(std::move(qt));

  // Called directly, with no ModularFrameEncoder, so it takes the inline
  // ModularGenericCompress path rather than deferring to a shared stream.
  // That is the stream the Swift port has to reproduce.
  BitWriter writer(memory_manager);
  if (!ModularFrameEncoder::EncodeQuantTable(
          memory_manager, kBlockDim, kBlockDim, &writer, encoding,
          static_cast<size_t>(QuantTable::DCT),
          /*modular_frame_encoder=*/nullptr)) {
    fprintf(stderr, "EncodeQuantTable failed\n");
    return 1;
  }
  size_t bits = writer.BitsWritten();
  writer.ZeroPadToByte();
  auto span = writer.GetSpan();
  printf("BITS %zu\nBYTES", bits);
  for (size_t i = 0; i < span.size(); i++) printf(" %02x", span.data()[i]);
  printf("\n");
  return 0;
}
