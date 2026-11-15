#include "registry.h"

#include <charconv>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <system_error>
#include <vector>

#include "lib/jxl/ac_context.h"
#include "lib/jxl/dec_context_map.h"
#include "lib/jxl/entropy_coder.h"
#include "lib/jxl/memory_manager_internal.h"

namespace harness {
namespace {

bool ParseSize(const std::string& text, size_t* value) {
  const char* begin = text.data();
  const char* end = begin + text.size();
  const auto result = std::from_chars(begin, end, *value);
  return result.ec == std::errc() && result.ptr == end;
}

bool ParseBits(const std::string& bit_count, const std::string& hex,
               size_t* bits, std::vector<uint8_t>* bytes) {
  if (!ParseSize(bit_count, bits) || *bits == 0) return false;
  const size_t byte_count = *bits / 8 + (*bits % 8 != 0);
  if (hex.size() % 2 != 0 || hex.size() / 2 != byte_count) return false;
  bytes->resize(byte_count);
  for (size_t i = 0; i < byte_count; ++i) {
    unsigned int value;
    const char* begin = hex.data() + 2 * i;
    const auto result = std::from_chars(begin, begin + 2, value, 16);
    if (result.ec != std::errc() || result.ptr != begin + 2 || value > 255) {
      return false;
    }
    (*bytes)[i] = static_cast<uint8_t>(value);
  }
  return true;
}

template <class T>
void PrintValues(const char* name, const std::vector<T>& values) {
  std::printf("%s=", name);
  for (size_t i = 0; i < values.size(); ++i) {
    if (i != 0) std::putchar(',');
    std::printf("%u", static_cast<unsigned int>(values[i]));
  }
  std::putchar('\n');
}

void PrintSignedValues(const char* name, const std::vector<int>& values) {
  std::printf("%s=", name);
  for (size_t i = 0; i < values.size(); ++i) {
    if (i != 0) std::putchar(',');
    std::printf("%d", values[i]);
  }
  std::putchar('\n');
}

int DecodeContextMapCommand(const std::vector<std::string>& args) {
  size_t entry_count;
  size_t bit_count;
  std::vector<uint8_t> bytes;
  if (args.size() != 3 || !ParseSize(args[0], &entry_count) ||
      entry_count == 0 || entry_count > (1u << 20) ||
      !ParseBits(args[1], args[2], &bit_count, &bytes)) {
    return 2;
  }

  JxlMemoryManager memory_manager;
  if (!jxl::MemoryManagerInit(&memory_manager, nullptr)) return 1;
  jxl::BitReader reader(bytes);
  std::vector<uint8_t> context_map(entry_count);
  size_t num_histograms = 0;
  const bool decoded = static_cast<bool>(jxl::DecodeContextMap(
      &memory_manager, &context_map, &num_histograms, &reader));
  const size_t consumed = reader.TotalBitsConsumed();
  const bool closed = static_cast<bool>(reader.Close());

  std::printf(
      "decode_succeeded=%d\ntotal_bits_consumed=%zu\nclose_succeeded=%d\n",
      decoded, consumed, closed);
  if (decoded) {
    std::printf("num_histograms=%zu\n", num_histograms);
    PrintValues("entries", context_map);
  }
  return 0;
}

int DecodeBlockContextMapCommand(const std::vector<std::string>& args) {
  size_t bit_count;
  std::vector<uint8_t> bytes;
  if (args.size() != 2 || !ParseBits(args[0], args[1], &bit_count, &bytes)) {
    return 2;
  }

  JxlMemoryManager memory_manager;
  if (!jxl::MemoryManagerInit(&memory_manager, nullptr)) return 1;
  jxl::BitReader reader(bytes);
  jxl::BlockCtxMap block_context_map;
  const bool decoded = static_cast<bool>(jxl::DecodeBlockCtxMap(
      &memory_manager, &reader, &block_context_map));
  const size_t consumed = reader.TotalBitsConsumed();
  const bool closed = static_cast<bool>(reader.Close());

  std::printf(
      "decode_succeeded=%d\ntotal_bits_consumed=%zu\nclose_succeeded=%d\n",
      decoded, consumed, closed);
  if (decoded) {
    for (size_t i = 0; i < 3; ++i) {
      const char name[] = {'d', 'c', static_cast<char>('0' + i), '\0'};
      PrintSignedValues(name, block_context_map.dc_thresholds[i]);
    }
    PrintValues("qf_thresholds", block_context_map.qf_thresholds);
    std::printf("num_dc=%zu\nnum_contexts=%zu\n",
                block_context_map.num_dc_ctxs, block_context_map.num_ctxs);
    PrintValues("context_map", block_context_map.ctx_map);
  }
  return 0;
}

const RegisterSubcommand kRegisterContextMap({
    "decode-context-map", "<entry_count> <bit_count> <hex>",
    DecodeContextMapCommand});
const RegisterSubcommand kRegisterBlockContextMap({
    "decode-block-context-map", "<bit_count> <hex>",
    DecodeBlockContextMapCommand});

}  // namespace
}  // namespace harness
