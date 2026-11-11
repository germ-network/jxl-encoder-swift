// Writer for the semantic dump text format (Reference/semantic-dump.md), the
// format Tests/JXLEncoderTests/SemanticDump.swift parses.
#ifndef JXL_HARNESS_SEMANTIC_DUMP_H_
#define JXL_HARNESS_SEMANTIC_DUMP_H_

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

namespace harness {

class SemanticDumpWriter {
 public:
  // A name recorded twice aborts: it's a dumper bug, never data.
  void Integers(const std::string& name, const std::vector<int64_t>& values);
  void Floats(const std::string& name, const std::vector<float>& values);

  // Header line, then fields sorted by name.
  void Write(FILE* out) const;

 private:
  struct Field {
    bool is_float;
    std::vector<int64_t> integers;
    std::vector<float> floats;
  };
  std::map<std::string, Field> fields_;
};

}  // namespace harness

#endif  // JXL_HARNESS_SEMANTIC_DUMP_H_
