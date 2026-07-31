# Building libjxl for the JPEG transcode

libjxl-tiny has no JPEG path, so the transcode stage has no reference to diff
against there. Full libjxl supplies two things instead: `cjxl --lossless_jpeg=1`
as a reference encoder, and — more useful — a **debug decoder that names the
check a malformed stream fails**.

Release builds compile the messages out. `StatusMessage` only prints under
`JXL_IS_DEBUG_BUILD`, so a `Debug` configuration is what makes the difference
between "Failed to decode image" and `quant_weights.cc:431: JXL_FAILURE:
Invalid mode`.

```bash
git clone --depth 1 https://github.com/libjxl/libjxl.git ~/tmp/automation/libjxl-full
cd ~/tmp/automation/libjxl-full
for m in third_party/highway third_party/brotli third_party/skcms; do
	git submodule update --init --depth 1 $m
done
cmake -S . -B build-dbg -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=OFF \
	-DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
	-DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
	-DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF \
	-DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=ON \
	-DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF
cmake --build build-dbg --target djxl -j8
```

Then read the failure off a rejected file:

```bash
build-dbg/tools/djxl ours.jxl /tmp/out.png 2>&1 | grep FAILURE
```

A dump tool for libjxl's own `EncodeQuantTable` was tried first and abandoned:
it segfaults when called without a `ModularFrameEncoder`, and the debug decoder
answered the question before it was worth fixing. Instrumenting that decoder to
print what it reconstructs — quant tables, DC, AC coefficients — is the
technique that actually worked.
