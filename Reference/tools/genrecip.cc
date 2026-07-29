// Dumps vrecpeq_f32 results as a fixture. libjxl-tiny's AdjustQuantBias uses
// Highway's ApproximateReciprocal, which is this instruction on arm64 but an
// exact division in the portable fallback — so the reference's own output
// depends on the target, and the port must pick one and reproduce it.
#include <stdio.h>
#include <stdint.h>
#include <arm_neon.h>
#include <vector>

int main(int argc, char** argv) {
  std::vector<uint32_t> out;
  auto emit = [&](float v) {
    float32x4_t in = vdupq_n_f32(v);
    float r = vgetq_lane_f32(vrecpeq_f32(in), 0);
    uint32_t vb, rb;
    __builtin_memcpy(&vb, &v, 4);
    __builtin_memcpy(&rb, &r, 4);
    out.push_back(vb);
    out.push_back(rb);
  };
  // quantized coefficient magnitudes reaching the reciprocal path, plus a
  // dense sweep of mantissas to exercise the estimate table
  for (int i = 2; i <= 4096; ++i) { emit((float)i); emit(-(float)i); }
  for (int i = 0; i < 2048; ++i) emit(1.0f + (float)i / 2048.0f);
  for (int e = -20; e <= 20; ++e) {
    for (int m = 0; m < 64; ++m) {
      float v = ldexpf(1.0f + m / 64.0f, e);
      emit(v);
    }
  }
  FILE* f = fopen(argv[1], "wb");
  fwrite(out.data(), sizeof(uint32_t), out.size(), f);
  fclose(f);
  fprintf(stderr, "wrote %zu pairs -> %s\n", out.size() / 2, argv[1]);
  return 0;
}
