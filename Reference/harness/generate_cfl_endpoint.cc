#include <cstdio>
#include <cstdlib>

extern "C" {
#include <jpeglib.h>
}

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  FILE* output = std::fopen(argv[1], "wb");
  if (output == nullptr) return 1;

  jpeg_compress_struct compressor{};
  jpeg_error_mgr errors{};
  compressor.err = jpeg_std_error(&errors);
  jpeg_create_compress(&compressor);
  jpeg_stdio_dest(&compressor, output);
  compressor.image_width = 8;
  compressor.image_height = 8;
  compressor.input_components = 3;
  compressor.in_color_space = JCS_YCbCr;
  jpeg_set_defaults(&compressor);
  for (int c = 0; c < 3; ++c) {
    compressor.comp_info[c].component_id = c + 1;
    compressor.comp_info[c].h_samp_factor = 1;
    compressor.comp_info[c].v_samp_factor = 1;
    compressor.comp_info[c].quant_tbl_no = 0;
  }
  for (int i = 0; i < DCTSIZE2; ++i) compressor.quant_tbl_ptrs[0]->quantval[i] = 1;

  jvirt_barray_ptr arrays[3];
  for (int c = 0; c < 3; ++c) {
    arrays[c] = (*compressor.mem->request_virt_barray)(
        reinterpret_cast<j_common_ptr>(&compressor), JPOOL_IMAGE, TRUE, 1, 1, 1);
  }
  jpeg_write_coefficients(&compressor, arrays);
  for (int c = 0; c < 3; ++c) {
    JBLOCKARRAY row = (*compressor.mem->access_virt_barray)(
        reinterpret_cast<j_common_ptr>(&compressor), arrays[c], 0, 1, TRUE);
    for (int k = 0; k < DCTSIZE2; ++k) row[0][0][k] = 0;
  }
  JBLOCKARRAY y = (*compressor.mem->access_virt_barray)(
      reinterpret_cast<j_common_ptr>(&compressor), arrays[0], 0, 1, TRUE);
  JBLOCKARRAY cb = (*compressor.mem->access_virt_barray)(
      reinterpret_cast<j_common_ptr>(&compressor), arrays[1], 0, 1, TRUE);
  y[0][0][1] = 84;
  y[0][0][2] = 84;
  cb[0][0][1] = 128;
  cb[0][0][2] = 128;
  jpeg_finish_compress(&compressor);
  jpeg_destroy_compress(&compressor);
  return std::fclose(output) == 0 ? 0 : 1;
}
