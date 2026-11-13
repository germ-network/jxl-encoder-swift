#include <algorithm>
#include <array>
#include <cstdio>
#include <limits>
#include <vector>
#include "hwy/base.h"
#include "hwy/highway.h"
#include "lib/jxl/enc_adaptive_quantization.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/quantizer.h"
#include "lib/jxl/quant_weights.h"
#include "registry.h"
#include "semantic_dump.h"
namespace harness { namespace {
jxl::Status WriteDistanceParams(const std::string& output) {
  if (HWY_TARGET != HWY_NEON) return false;
  constexpr std::array<float, 15> boundaries = {0.03f,0.05f,0.299f,0.5f,0.7f,1.25f,1.5f,2.5f,3.0f,4.0f,5.0f,5.5f,9.0f,9.5f,10.0f};
  std::vector<float> inputs;
  for (float boundary : boundaries) {
    inputs.push_back(std::nextafter(boundary, -std::numeric_limits<float>::infinity()));
    inputs.push_back(boundary);
    inputs.push_back(std::nextafter(boundary, std::numeric_limits<float>::infinity()));
  }
  JxlMemoryManager memory_manager;
  JXL_RETURN_IF_ERROR(jxl::MemoryManagerInit(&memory_manager, nullptr));
  jxl::DequantMatrices matrices;
  JXL_RETURN_IF_ERROR(matrices.EnsureComputed(&memory_manager, 1));
  std::vector<int64_t> input_bits, global_scales, quant_dcs, quant_fields;
  std::vector<float> effective_distances;
  for (float input : inputs) {
    const float distance = std::max(input, 0.03f);
    const float q = static_cast<float>(0.79 / distance);
    const float quant_dc = jxl::InitialQuantDC(distance);
    jxl::Quantizer quantizer(matrices, 1, 1);
    quantizer.ComputeGlobalScaleAndQuant(quant_dc, q, 0);
    JXL_ASSIGN_OR_RETURN(auto quant_field, jxl::ImageF::Create(&memory_manager, 1, 1));
    JXL_ASSIGN_OR_RETURN(auto raw_quant_field, jxl::ImageI::Create(&memory_manager, 1, 1));
    quant_field.Row(0)[0] = q;
    quantizer.SetQuantFieldRect(quant_field, jxl::Rect(quant_field), &raw_quant_field);
    const auto params = quantizer.GetParams();
    input_bits.push_back(static_cast<int64_t>(hwy::BitCastScalar<uint32_t>(input)));
    effective_distances.push_back(distance);
    global_scales.push_back(params.global_scale);
    quant_dcs.push_back(params.quant_dc);
    quant_fields.push_back(raw_quant_field.Row(0)[0]);
  }
  SemanticDumpWriter dump;
  dump.Integers("distance_params.neon_target", {1});
  dump.Integers("distance_params.inputs", input_bits);
  dump.Floats("distance_params.effective_distance", effective_distances);
  dump.Integers("distance_params.global_scale", global_scales);
  dump.Integers("distance_params.quant_dc", quant_dcs);
  dump.Integers("distance_params.quant_field", quant_fields);
  FILE* file = std::fopen(output.c_str(), "w");
  if (!file) return false;
  dump.Write(file);
  return std::fclose(file) == 0;
}
int RunDistanceParams(const std::vector<std::string>& args) {
  if (args.size() != 1) return 2;
  return WriteDistanceParams(args[0]) ? 0 : 1;
}
const RegisterSubcommand kRegister({"distance-params", "<out.sem>", RunDistanceParams});
} }
