#include "semantic_dump.h"
#include <clocale>
#include <cmath>
#include <cstdlib>
namespace harness {
void SemanticDumpWriter::Integers(const std::string& name, const std::vector<int64_t>& values) {
  if (!fields_.emplace(name, Field{false, values, {}}).second) std::abort();
}
void SemanticDumpWriter::Floats(const std::string& name, const std::vector<float>& values) {
  for (float value : values) if (!std::isfinite(value)) std::abort();
  if (!fields_.emplace(name, Field{true, {}, values}).second) std::abort();
}
void SemanticDumpWriter::Write(FILE* out) const {
  std::setlocale(LC_NUMERIC, "C");
  std::fprintf(out, "jxl-semantic-dump 1\n");
  for (const auto& entry : fields_) {
    const auto& field = entry.second;
    std::fprintf(out, "%s %c %zu", entry.first.c_str(), field.is_float ? 'f' : 'i', field.is_float ? field.floats.size() : field.integers.size());
    if (field.is_float) { for (float value : field.floats) std::fprintf(out, " %.9g", value); }
    else { for (int64_t value : field.integers) std::fprintf(out, " %lld", static_cast<long long>(value)); }
    std::fprintf(out, "\n");
  }
}
}  // namespace harness
