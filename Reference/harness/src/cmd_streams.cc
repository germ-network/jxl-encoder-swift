#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "lib/jxl/dec_ans.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/memory_manager_internal.h"
#include "registry.h"

namespace harness {
namespace {

using Fields = std::unordered_map<std::string, std::vector<int64_t>>;

bool ReadIntegerFields(const std::string &path, Fields *fields) {
  std::ifstream input(path);
  std::string line;
  if (!std::getline(input, line) || line != "jxl-semantic-dump 1")
    return false;
  while (std::getline(input, line)) {
    std::istringstream row(line);
    std::string name;
    char kind = 0;
    size_t count = 0;
    if (!(row >> name >> kind >> count) || kind != 'i' || count > 1'000'000)
      return false;
    std::vector<int64_t> values(count);
    for (int64_t &value : values) {
      if (!(row >> value))
        return false;
    }
    std::string extra;
    if (row >> extra || !fields->emplace(name, std::move(values)).second)
      return false;
  }
  return input.eof();
}

const std::vector<int64_t> *Get(const Fields &fields, const char *name) {
  const auto it = fields.find(name);
  return it == fields.end() ? nullptr : &it->second;
}

bool ParseBytes(const std::vector<int64_t> *values,
                std::vector<uint8_t> *bytes) {
  if (values == nullptr || values->empty())
    return false;
  bytes->reserve(values->size());
  for (const int64_t value : *values) {
    if (value < 0 || value > 255)
      return false;
    bytes->push_back(static_cast<uint8_t>(value));
  }
  return true;
}

bool HasZeroPadding(const std::vector<uint8_t> &bytes, size_t bit_count) {
  const size_t byte_count = bit_count / 8 + (bit_count % 8 != 0);
  if (bit_count == 0 || bytes.size() != byte_count)
    return false;
  const unsigned used = bit_count % 8;
  return used == 0 || (bytes.back() >> used) == 0;
}

bool DecodeOne(const jxl::ANSCode &code,
               const std::vector<uint8_t> &context_map,
               const std::vector<uint8_t> &bytes, size_t bit_count,
               const std::vector<std::pair<uint32_t, uint32_t>> &expected,
               std::vector<int64_t> *receipt, std::string *error) {
  jxl::BitReader reader(bytes);
  jxl::Status closed = true;
  const bool valid = [&]() {
    jxl::BitReaderScopedCloser closer(reader, closed);
    auto decoder_or = jxl::ANSSymbolReader::Create(&code, &reader);
    if (!decoder_or.ok()) {
      *error = "symbol reader initialization failed";
      return false;
    }
    jxl::ANSSymbolReader decoder = std::move(decoder_or).value_();
    bool tokens_match = true;
    for (const auto &[context, value] : expected) {
      if (context >= context_map.size()) {
        *error = "invalid token context";
        return false;
      }
      const size_t actual =
          decoder.ReadHybridUintInlined<false>(context, &reader, context_map);
      tokens_match = tokens_match && actual == value;
    }
    const bool final_state = decoder.CheckANSFinalState();
    const size_t consumed = reader.TotalBitsConsumed();
    if (!reader.AllReadsWithinBounds()) {
      *error = "stream reader exceeded bounds";
      return false;
    }
    if (!final_state) {
      *error = "final ANS state mismatch";
      return false;
    }
    if (consumed != bit_count) {
      *error = "stream bit count mismatch";
      return false;
    }
    if (!tokens_match) {
      *error = "decoded token mismatch";
      return false;
    }
    receipt->push_back(static_cast<int64_t>(consumed));
    receipt->push_back(final_state ? 1 : 0);
    return true;
  }();
  if (!closed) {
    *error = "stream reader close failed";
    return false;
  }
  return valid;
}

int RunVerifyStreams(const std::vector<std::string> &args) {
  if (args.size() != 1)
    return 2;
  Fields fields;
  if (!ReadIntegerFields(args[0], &fields))
    return 2;
  const auto *context_count =
      Get(fields, "entropy.streams.transmitted_context_count");
  const auto *expected_code_kind = Get(fields, "entropy.streams.code_kind");
  const auto *code_bit_count = Get(fields, "entropy.streams.code_bit_count");
  const auto *lengths = Get(fields, "entropy.streams.lengths");
  const auto *token_records = Get(fields, "entropy.streams.tokens");
  const auto *bit_counts = Get(fields, "entropy.streams.bit_counts");
  const auto *stream_bytes = Get(fields, "entropy.streams.bytes");
  std::vector<uint8_t> code_bytes;
  if (context_count == nullptr || context_count->size() != 1 ||
      context_count->front() <= 0 || context_count->front() > 4096 ||
      expected_code_kind == nullptr || expected_code_kind->size() != 1 ||
      ((*expected_code_kind)[0] != 0 && (*expected_code_kind)[0] != 1) ||
      code_bit_count == nullptr || code_bit_count->size() != 1 ||
      code_bit_count->front() < 1 || lengths == nullptr ||
      lengths->size() != 2 || bit_counts == nullptr ||
      bit_counts->size() != lengths->size() || stream_bytes == nullptr ||
      token_records == nullptr ||
      !ParseBytes(Get(fields, "entropy.streams.code_bytes"), &code_bytes))
    return 2;
  if (static_cast<uint64_t>(code_bit_count->front()) >
          static_cast<uint64_t>(code_bytes.size()) * 8 ||
      !HasZeroPadding(code_bytes, static_cast<size_t>(code_bit_count->front())))
    return 2;

  std::vector<std::vector<std::pair<uint32_t, uint32_t>>> streams(
      lengths->size());
  size_t token_offset = 0;
  for (size_t stream = 0; stream < streams.size(); ++stream) {
    if ((*lengths)[stream] < 0 || (*lengths)[stream] > 1'000'000 ||
        token_offset + 2 > token_records->size() ||
        (*token_records)[token_offset++] != static_cast<int64_t>(stream) ||
        (*token_records)[token_offset++] != (*lengths)[stream])
      return 2;
    streams[stream].reserve(static_cast<size_t>((*lengths)[stream]));
    for (int64_t token = 0; token < (*lengths)[stream]; ++token) {
      if (token_offset + 2 > token_records->size())
        return 2;
      const int64_t context = (*token_records)[token_offset++];
      const int64_t value = (*token_records)[token_offset++];
      if (context < 0 || context > UINT32_MAX || value < 0 ||
          value > UINT32_MAX)
        return 2;
      streams[stream].emplace_back(static_cast<uint32_t>(context),
                                   static_cast<uint32_t>(value));
    }
  }
  if (token_offset != token_records->size())
    return 2;
  std::vector<uint8_t> encoded_streams;
  if (!ParseBytes(stream_bytes, &encoded_streams))
    return 2;
  std::vector<std::vector<uint8_t>> per_stream_bytes(streams.size());
  size_t byte_offset = 0;
  for (size_t i = 0; i < streams.size(); ++i) {
    if ((*bit_counts)[i] < 1 ||
        static_cast<uint64_t>((*bit_counts)[i]) >
            static_cast<uint64_t>(encoded_streams.size()) * 8)
      return 2;
    const size_t size = (static_cast<size_t>((*bit_counts)[i]) + 7) / 8;
    if (byte_offset + size > encoded_streams.size())
      return 2;
    per_stream_bytes[i].assign(encoded_streams.begin() + byte_offset,
                               encoded_streams.begin() + byte_offset + size);
    byte_offset += size;
  }
  if (byte_offset != encoded_streams.size())
    return 2;
  byte_offset = 0;
  for (size_t i = 0; i < streams.size(); ++i) {
    const size_t size = (static_cast<size_t>((*bit_counts)[i]) + 7) / 8;
    const std::vector<uint8_t> bytes(encoded_streams.begin() + byte_offset,
                                     encoded_streams.begin() + byte_offset +
                                         size);
    if (!HasZeroPadding(bytes, static_cast<size_t>((*bit_counts)[i])))
      return 2;
    byte_offset += size;
  }

  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr))
    return 1;
  jxl::BitReader code_reader(code_bytes);
  jxl::ANSCode code;
  std::vector<uint8_t> context_map;
  jxl::Status code_closed = true;
  bool code_decoded = false;
  bool code_in_bounds = false;
  size_t code_consumed = 0;
  {
    jxl::BitReaderScopedCloser closer(code_reader, code_closed);
    code_decoded = jxl::DecodeHistograms(
        &manager, &code_reader, static_cast<size_t>(context_count->front()),
        &code, &context_map, /*disallow_lz77=*/true);
    code_in_bounds = code_reader.AllReadsWithinBounds();
    code_consumed = code_reader.TotalBitsConsumed();
  }
  if (!code_closed) {
    std::fprintf(stderr, "stream verifier: shared code close failed\n");
    return 1;
  }
  if (!code_decoded ||
      context_map.size() != static_cast<size_t>(context_count->front())) {
    std::fprintf(stderr, "stream verifier: shared code decode failed\n");
    return 1;
  }
  if (!code_in_bounds ||
      code.use_prefix_code != ((*expected_code_kind)[0] == 0) ||
      code_consumed != static_cast<size_t>(code_bit_count->front()))
    return 1;

  std::vector<int64_t> decode_receipt;
  const size_t decoded_values = streams[0].size() + streams[1].size();
  const size_t passes[2][2] = {{0, 1}, {1, 0}};
  for (const auto &order : passes) {
    for (size_t stream : order) {
      std::string error;
      if (!DecodeOne(code, context_map, per_stream_bytes[stream],
                     static_cast<size_t>((*bit_counts)[stream]),
                     streams[stream], &decode_receipt, &error)) {
        std::fprintf(stderr, "stream verifier: stream %zu failed: %s\n", stream,
                     error.c_str());
        return 1;
      }
    }
  }
  SemanticDumpWriter dump;
  dump.Integers("entropy.stream_receipt.code_is_ans",
                {code.use_prefix_code ? 0 : 1});
  dump.Integers("entropy.stream_receipt.code_bytes_consumed",
                {static_cast<int64_t>(code_consumed)});
  dump.Integers("entropy.stream_receipt.code_bit_count", *code_bit_count);
  dump.Integers("entropy.stream_receipt.code_bytes",
                std::vector<int64_t>(code_bytes.begin(), code_bytes.end()));
  dump.Integers("entropy.stream_receipt.stream_bit_counts", *bit_counts);
  dump.Integers(
      "entropy.stream_receipt.stream_bytes",
      std::vector<int64_t>(encoded_streams.begin(), encoded_streams.end()));
  dump.Integers("entropy.stream_receipt.stream_count",
                {static_cast<int64_t>(streams.size())});
  dump.Integers("entropy.stream_receipt.decoded_token_count",
                {static_cast<int64_t>(decoded_values)});
  dump.Integers("entropy.stream_receipt.order_passes", {0, 1, 1, 0});
  dump.Integers("entropy.stream_receipt.readers", decode_receipt);
  dump.Write(stdout);
  return 0;
}

const RegisterSubcommand kRegister({"entropy-verify-streams",
                                    "<swift-token-stream-dump.sem>",
                                    RunVerifyStreams});

} // namespace
} // namespace harness
