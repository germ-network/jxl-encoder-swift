# Selected-reference sort provenance

2026-11-15. This is the NEW explicitly selected producer configuration for the pixel-model reference artifacts. It makes no claim about historical fixtures. Source libjxl pin a7a9c787341cf703dede03c2009fa460cae5e5df. Normalized compile invocations are in `pixel-model-producer-commands.json`; local paths use `$REPO`, `$LIBJXL`, `$BUILD`, and `$XCODE_DEVELOPER_DIR`.

## Actual configured translation unit

`compile_commands.json` selects Xcode 27.2 clang++, arm64, explicit MacOSX.sdk, C++17, Release -O3 -DNDEBUG. Compiler reports Apple clang21.0.0 (clang-2100.4.1.1). Exact command:

```text
"$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++" -DFJXL_ENABLE_AVX512=0 -DJXL_INTERNAL_LIBRARY_BUILD -D__DATE__=\"redacted\" -D__TIMESTAMP__=\"redacted\" -D__TIME__=\"redacted\" -I$LIBJXL -I$LIBJXL/third_party/highway -I$LIBJXL/third_party/brotli/c/include -I$BUILD/libjxl/lib/include  -fno-rtti -O3 -DNDEBUG -std=c++17 -arch arm64 -isysroot "$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" -fPIC -fvisibility=hidden -fvisibility-inlines-hidden "-DHWY_DISABLED_TARGETS=(HWY_AVX3|HWY_AVX3_SPR|HWY_AVX3_ZEN4|HWY_NEON_BF16|HWY_RVV|HWY_SSSE3|HWY_SVE_256)" -fmacro-prefix-map=$LIBJXL=. -funwind-tables -Xclang -mrelax-all -fno-omit-frame-pointer -Wno-builtin-macro-redefined -Wall -fmerge-all-constants -fno-builtin-fwrite -fno-builtin-fread -Wextra -Wc++11-compat -Warray-bounds -Wformat-security -Wimplicit-fallthrough -Wno-register -Wno-unused-function -Wno-unused-parameter -Wnon-virtual-dtor -Woverloaded-virtual -Wvla -Wframe-larger-than=5632 -Wdeprecated-increment-bool -Wfloat-overflow-conversion -Wfloat-zero-conversion -Wfor-loop-analysis -Wgnu-redeclared-enum -Winfinite-recursion -Wliteral-conversion -Wno-c++98-compat -Wno-unused-command-line-argument -Wprivate-header -Wself-assign -Wshadow -Wstring-conversion -Wtautological-overlap-compare -Wthread-safety-analysis -Wundefined-func-template -Wunreachable-code -Wunused-comparison -fsized-deallocation -fno-exceptions -fmath-errno -fnew-alignment=8 -fno-cxx-exceptions -fno-slp-vectorize -fno-vectorize -disable-free -disable-llvm-verifier -DJPEGXL_ENABLE_SKCMS=1 -DJPEGXL_ENABLE_TRANSCODE_JPEG=1 -DJPEGXL_ENABLE_BOXES=1 -o CMakeFiles/jxl_enc-obj.dir/jxl/enc_heuristics.cc.o -c $LIBJXL/lib/jxl/enc_heuristics.cc
```

Working directory: `$BUILD/libjxl/lib`.

## Preprocessing evidence

Read-only preprocessing of that exact command, replacing `-o … -c` with `-E -H -dM`, exited0. Include trace resolved sort.h and configuration/debug helpers under the SDK directory below. `_LIBCPP_VERSION=220106`, `_LIBCPP_ABI_VERSION=1`, `_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEFAULT`, default=2 (=NONE). `_LIBCPP_DEBUG_RANDOMIZE_UNSPECIFIED_STABILITY` absent. Thus randomize_range does nothing; comp_ref_type is reference rather than debug wrapper; strict-weak-order postcheck is inactive. NDEBUG alone is not the evidence for these choices.

SDK header directory: `$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/c++/v1`.

## Reachability and necessary helper closure

enc_heuristics.cc:128–157 sets segments1 or2. For segments1 cut=tot cannot be crossed. For segments2 crossing floor(tot/2) advances next to2 and cut to tot, which cannot be crossed. Crossing at j>0 appends one threshold; crossing j0 appends none and recovery may append exactly one at j1. Recovery condition becomes false after that append. This assumes valid nonoverflow image totals/counts. Therefore qft.size<=1 and kNumOrders13 gives initial remap13 or26;39 is unreachable. Merge calls subsequently shrink one element each time.

Comparator is exactly counts[a]>counts[b], with no invented tie breaker. Capturing lambda does not satisfy __desugars_to less/greater trait (sort.h:54); branchless/bitset path is inactive. Required selected path: sort→sort_impl→sort_dispatch→introsort, nonbranchless sort3/4/5, guarded/unguarded insertion, incomplete insertion, median-of-three and equal-right/equal-left partitions. Plain moves/swaps preserve byte values. Source references sort.h:112,161,205,244,274,302,587,655,717,862,930. Preserve all comparison directions and swap/move ordering.

Length<24 selects insertion (special0…5 first). Length26/25/24 may partition. Initial depth2*floor(log2(n)) is8 for24…26. Every partition removes at least its pivot from each continuing subproblem; the equal-left path also advances first past at least its pivot. Therefore any path starting<=26 performs at most3 partitions before reaching<24. Heap depth fallback is provably unreachable; no heap translation needed for this bounded caller. Ninther threshold128 is likewise unreachable. Special3/4/5 remain relevant to partition children and incomplete insertion. The port must enforce caller maximum26 rather than claim universal std::sort semantics. The guarded, unguarded, and incomplete insertion loops preserve the source's exact do/move-then-compare order; the nonuniform source-produced witness records, with repeated counts to exercise unspecified tie ordering, cover every reachable input length from3 through26, including the 24→23 partition transition.

## Existing Swift mechanisms

Search of Sources/JXLEncoder found only standard Swift sorted calls in CoeffOrder.swift and HuffmanTree.swift (the latter supplies explicit original-position tie keys), and an unrelated prefix-code insertion-by-depth. No reusable matching libc++ partition mechanism found. Reusing those Swift ordering choices would change this comparator's tie outcomes.

## License and hashes

The translated source carries a changed-file notice. `Reference/NOTICE` attributes the translation and `Reference/LLVM-LICENSE.txt` preserves the complete LLVM license text, including the Apache 2.0 terms and LLVM exception.

sort.h declares `Apache-2.0 WITH LLVM-exception` and points to https://llvm.org/LICENSE.txt. The changed-file notice is in the Swift source, and the complete license text and attribution are provided in `Reference/LLVM-LICENSE.txt` and `Reference/NOTICE`.

SHA256:
- `__algorithm/sort.h`: `b644503828e13c3c90b5d343684eb993add9330762c5a7957001876be653e014`
- `__config`: `faaaec9312f1d28c6fda9cb19c144e4e0e8beb9c574c10d31e557e39141700c7`
- `__config_site`: `3ac5af56abfebec68f3ddc02f17f2312687441a5c3e0b11a450ef51480902413`
- `__configuration/hardening.h`: `f4d7772da2ecb26fc88add23da04c9295197e35082bc19bd67072b586fabae17`
- `__algorithm/comp_ref_type.h`: `28e248bee0ac242eb3f18b33456d027c09eafd2812db2c13be700663e9f502b5`
- `__debug_utils/randomize_range.h`: `ed04ac54864bffe1577b762e3ea8e1d59387fbd2ed91096597709685b9f25700`
- `__debug_utils/strict_weak_ordering_check.h`: `275021c29928c3e6e3be03f00977cffb7040d85ed8099d93f4108e4f074a3b49`

## Completed producer artifacts
Captured producer artifacts: `enc_heuristics.cc.o` SHA-256 `21abe78e755632293770db2d2e14cfb6fafb0eb3c6a3efc19aa75079a1b34838`; initial harness SHA-256 `1440ea0f68492616b742ce33cb6caf067c7bd087d0dfe0ab91813665cdc0d3ef`. After adding `cmd_pixel_block_model.cc` and `cmd_pixel_sort_witness.cc`, the selected harness was rebuilt and both new objects were compiled by the configured CMake command. Their exact compiler commands are in `pixel-model-producer-commands.json`. The model probe calls pinned upstream `FindBestBlockEntropyModel` with real `ImageI` and all-DCT8 `AcStrategyImage`; the sort witness calls selected libc++ `std::sort` with the source comparator for lengths 3...26. Fixture provenance records the resulting outputs. Preprocessing captures for the upstream encoder and original harness translation units were checked during selection; the relevant resolved libc++ header hashes and macros are recorded above. Harness writer/read selftest with two output arguments passed. Initial argument-free selftest exited 2 (usage), not counted. Pin-check after build passed.
