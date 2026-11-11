#include "semantic_dump.h"

#include <cstdlib>

namespace harness {

void SemanticDumpWriter::Integers(const std::string& name,
                                  const std::vector<int64_t>& values) {
  std::abort();
}

void SemanticDumpWriter::Floats(const std::string& name,
                                const std::vector<float>& values) {
  std::abort();
}

void SemanticDumpWriter::Write(FILE* out) const { std::abort(); }

}  // namespace harness
