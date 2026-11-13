#include <cstdio>
#include <vector>

#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/quant_weights.h"
#include "registry.h"

namespace harness {
namespace {

int RunPixelMatrices(const std::vector<std::string>& args) {
  if (args.size() != 1) return 2;
  JxlMemoryManager manager;
  if (!jxl::MemoryManagerInit(&manager, nullptr)) return 1;
  jxl::DequantMatrices matrices;
  const uint32_t dct8 = 1u << static_cast<uint32_t>(jxl::AcStrategyType::DCT);
  if (!matrices.EnsureComputed(&manager, dct8)) return 1;

  SemanticDumpWriter dump;
	std::vector<float> dc_quant;
	std::vector<float> inverse_dc_quant;
  for (size_t channel = 0; channel < 3; ++channel) {
    const std::string suffix = ".dct8.c" + std::to_string(channel);
    const float* forward = matrices.Matrix(jxl::AcStrategyType::DCT, channel);
    const float* inverse = matrices.InvMatrix(jxl::AcStrategyType::DCT, channel);
		dump.Floats("quant_matrix" + suffix, std::vector<float>(forward, forward + 64));
		dump.Floats("inverse_quant_matrix" + suffix, std::vector<float>(inverse, inverse + 64));
		dc_quant.push_back(matrices.DCQuant(channel));
		inverse_dc_quant.push_back(matrices.InvDCQuant(channel));
  }
	dump.Floats("dc_quant_matrix.values", dc_quant);
	dump.Floats("inverse_dc_quant_matrix.values", inverse_dc_quant);

  FILE* out = std::fopen(args[0].c_str(), "wb");
  if (out == nullptr) return 1;
  dump.Write(out);
  return std::fclose(out) == 0 ? 0 : 1;
}

const RegisterSubcommand kRegister({"pixel-matrices", "<out.sem>", RunPixelMatrices});

}  // namespace
}  // namespace harness
