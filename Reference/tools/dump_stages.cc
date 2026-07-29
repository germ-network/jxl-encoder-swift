// Dumps libjxl-tiny's intermediate stages as raw float32 planes, so the Swift
// port can be diffed against the reference stage by stage.
//
// Deliberately links the upstream static library rather than patching the
// vendored checkout, so tiny stays a clean clone that can be updated.

#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#include "encoder/enc_xyb.h"
#include "encoder/image.h"
#include "encoder/read_pfm.h"

namespace {

bool WritePlanes(const std::string& path, const jxl::Image3F& img) {
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", path.c_str());
    return false;
  }
  // header: magic, xsize, ysize, channel count (planar, channel-major)
  const uint32_t magic = 0x304D5544;  // "DUM0"
  const uint32_t xsize = img.xsize(), ysize = img.ysize(), channels = 3;
  fwrite(&magic, 4, 1, f);
  fwrite(&xsize, 4, 1, f);
  fwrite(&ysize, 4, 1, f);
  fwrite(&channels, 4, 1, f);
  for (size_t c = 0; c < 3; ++c) {
    for (size_t y = 0; y < ysize; ++y) {
      fwrite(img.PlaneRow(c, y), sizeof(float), xsize, f);
    }
  }
  fclose(f);
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <stage> <in.pfm> <out.dump>\n", argv[0]);
    fprintf(stderr, "  stages: linear, xyb\n");
    return 1;
  }
  const std::string stage = argv[1];

  jxl::Image3F image;
  if (!jxl::ReadPFM(argv[2], &image)) {
    fprintf(stderr, "failed to read %s\n", argv[2]);
    return 1;
  }

  if (stage == "linear") {
    // input as-is, to confirm the corpus round-trips before any transform
  } else if (stage == "xyb") {
    jxl::ToXYB(&image);
  } else {
    fprintf(stderr, "unknown stage: %s\n", stage.c_str());
    return 1;
  }

  if (!WritePlanes(argv[3], image)) return 1;
  fprintf(stderr, "%s: %zux%zu -> %s\n", stage.c_str(), image.xsize(),
          image.ysize(), argv[3]);
  return 0;
}
