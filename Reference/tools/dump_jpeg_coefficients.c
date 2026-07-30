// Dumps libjpeg's quantized DCT coefficients and quantization tables, so the
// Swift JPEG parser can be diffed against a reference decoder rather than
// against itself.
//
// libjpeg already stores blocks in natural (row-major) order — jpeg_natural_order
// scatters the zig-zag scan during Huffman decoding — and stores quantization
// tables the same way, so both come out in the layout JPEGParser produces.
//
// Coefficient rows are emitted padded up to the MCU grid, which is how libjpeg
// allocates them: those trailing blocks are coded like any other and the parser
// keeps them too.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// jpeglib.h uses size_t and FILE without including their headers itself.
#include <jpeglib.h>

static uint32_t roundup(uint32_t n, uint32_t f) { return ((n + f - 1) / f) * f; }

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: dump_jpeg_coefficients in.jpg out.coef\n");
		return 2;
	}
	FILE *in = fopen(argv[1], "rb");
	if (!in) { perror("open"); return 1; }

	struct jpeg_decompress_struct cinfo;
	struct jpeg_error_mgr jerr;
	cinfo.err = jpeg_std_error(&jerr);
	jpeg_create_decompress(&cinfo);
	jpeg_stdio_src(&cinfo, in);
	jpeg_read_header(&cinfo, TRUE);
	jvirt_barray_ptr *coefs = jpeg_read_coefficients(&cinfo);

	FILE *out = fopen(argv[2], "wb");
	put32(out, 0x3046434A);  // "JCF0"
	put32(out, cinfo.image_width);
	put32(out, cinfo.image_height);
	put32(out, cinfo.num_components);
	for (int c = 0; c < cinfo.num_components; c++) {
		jpeg_component_info *ci = &cinfo.comp_info[c];
		put32(out, ci->component_id);
		put32(out, ci->h_samp_factor);
		put32(out, ci->v_samp_factor);
		put32(out, ci->quant_tbl_no);
		put32(out, roundup(ci->width_in_blocks, ci->h_samp_factor));
		put32(out, roundup(ci->height_in_blocks, ci->v_samp_factor));
	}
	for (int c = 0; c < cinfo.num_components; c++) {
		jpeg_component_info *ci = &cinfo.comp_info[c];
		JDIMENSION width = roundup(ci->width_in_blocks, ci->h_samp_factor);
		JDIMENSION height = roundup(ci->height_in_blocks, ci->v_samp_factor);
		for (JDIMENSION by = 0; by < height; by++) {
			JBLOCKARRAY rows = (*cinfo.mem->access_virt_barray)(
				(j_common_ptr)&cinfo, coefs[c], by, 1, FALSE);
			for (JDIMENSION bx = 0; bx < width; bx++) {
				int16_t block[64];
				for (int k = 0; k < 64; k++) block[k] = (int16_t)rows[0][bx][k];
				fwrite(block, 2, 64, out);
			}
		}
	}
	for (int t = 0; t < 4; t++) {
		JQUANT_TBL *table = cinfo.quant_tbl_ptrs[t];
		put32(out, table ? 1 : 0);
		if (table) {
			for (int k = 0; k < 64; k++) put32(out, table->quantval[k]);
		}
	}

	fclose(out);
	jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);
	fclose(in);
	return 0;
}
