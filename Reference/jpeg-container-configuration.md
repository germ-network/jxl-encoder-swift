# Selected JPEG container configuration

The selected JPEG command remains `cjxl <input> <output>.jxl -d <D> -e 4 -j 1 --container=0`. This records what the pinned source passes to its API, not a claim about what an output comparison alone proves.

## Flag propagation

At libjxl v0.12.0 commit `a7a9c787341cf703dede03c2009fa460cae5e5df`, the reconstruction option defaults to enabled (tools/cjxl_main.cc:232-236,517). `ProcessFlags` runs once after file reading and again after lossless-JPEG detection retains `jpeg_bytes` (tools/cjxl_main.cc:1085,1110,1131). It copies `args.allow_jpeg_reconstruction` into `params.jpeg_store_metadata` (tools/cjxl_main.cc:922-923). The later `--container=0` branch sets `args.allow_jpeg_reconstruction = JXL_FALSE` only (tools/cjxl_main.cc:1148-1156), after that copy, so `params.jpeg_store_metadata` remains true. The original `jpeg_bytes` are retained and the unchanged params plus those bytes reach `EncodeImageJXL` (tools/cjxl_main.cc:1190). Thus the late CLI assignment does not disable reconstruction or metadata storage in the API parameters for this invocation.

## Container and metadata path

With original JPEG bytes and `params.jpeg_store_metadata` enabled, `EncodeImageJXL` forces container output and enables metadata storage (lib/extras/enc/jxl.cc:187-204,206-233). `JxlEncoderAddJPEGFrame` independently parses the original JPEG bytes to add recognized metadata boxes (lib/jxl/encode.cc:2251-2276). During encoding, `encode.cc` rereads those bytes and writes reconstruction and metadata boxes (lib/jxl/encode.cc:2182-2206,2244-2293; lib/jxl/jpeg/enc_jpeg_data.cc:286-410). The reference harness explicitly sets `StoreJPEGMetadata` before submitting original JPEG bytes (Reference/harness/src/cmd_encode_jpeg.cc:29-30).

Explicit `--allow_jpeg_reconstruction=0` together with `-x strip=exif -x strip=xmp -x strip=jumbf` is a different configuration. Those flags are not part of the selected command. Clearing metadata from decoded pixel metadata does not remove marker data from the separately retained original JPEG bytes.

## Distinct input paths and obligations

The pixel path has no original JPEG bytes and does not take this JPEG-container branch. This proof therefore makes no container claim about pixel-only input. For the selected JPEG path, JR-03 and JR-04 remain original, absent Swift decisions with outstanding GER-3388/GER-3389 coverage. The existing implementation's bare codestream behavior is a real difference: pixel source correspondence may be diagnosed separately, but it does not resolve the missing JPEG reconstruction/container and metadata behavior.

ICC and orientation decoded meaning remain required. There is no blanket metadata waiver or programme feature exclusion here. No source/spec conflict was identified in this review; this note does not claim broad JPEG XL standard conformance.
