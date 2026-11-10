# libjxl-tiny legacy reference tools

These tools, patches, and build scripts are from the initial development phase of this repository. They are **unpinned, frozen, and not part of the pinned reference build**. Porting reference stage dumps and generators to the pinned full libjxl is deferred.

## Upstream commit

Last observed libjxl-tiny upstream commit:
`8eae18172059d54f5c734ca814f23b96eebff859` (2023-02-17).
This commit hash is an observation of what upstream HEAD was when these artifacts were created, not a reproducibility pin. The pre-images in `patches/0001-test-hooks.patch` match this commit.

## Configuration (`encoder/config.h`)

All current gates using legacy-tiny fixtures run under the following configuration:

```c
#ifndef ENCODER_CONFIG_H_
#define ENCODER_CONFIG_H_

#define OPTIMIZE_CODE 0
#define OPTIMIZE_CHROMA_FROM_LUMA 0
#define OPTIMIZE_BLOCK_SIZES 0

#endif  // ENCODER_CONFIG_H_
```

Every current gate assumes `OPTIMIZE_CODE=0` (static prefix-code tables). Chroma-from-luma and variable block sizes are disabled.

## Build script

`build-tiny.sh` applies `patches/*.patch`, writes `encoder/config.h`, and builds `cjxl_tiny` along with all six legacy tools into `Reference/build/legacy-tiny/`:

```bash
TINY_DIR=/path/to/libjxl-tiny ./build-tiny.sh
```

`TINY_DIR` must be explicitly specified with no default.

## Tools and artifacts

The `stripe_*` stage names (`linear`, `dct`, `aq`) are inferred from fixture filenames.

| Tool | Artifact(s) | Invocation | Input |
|---|---|---|---|
| `dump_stages.cc` | `edge_{linear,xyb,dct,quant,dcgroup,acgroup,dcextract}.dump` | `dump_stages <stage> <in.pfm> <out.dump>` | unrecorded |
| `dump_stages.cc` | `stripe_{linear,dct,aq}.dump` | `dump_stages <stage inferred from filename> <in.pfm> <out.dump>` | unrecorded |
| `dump_stages.cc` | `multigroup_linear.dump` | `dump_stages linear <in.pfm> multigroup_linear.dump` | unrecorded (301x301 PFM) |
| `cjxl_tiny` | `edge_whole.jxl`, `multigroup_whole.jxl` | `cjxl_tiny -d 1.0 <in.pfm> <out.jxl>` | unrecorded |
| `gencodes.cc` | `Sources/JXLEncoder/StaticEntropyCodes.swift` | `gencodes` | unrecorded |
| `genctx.cc` | `Tests/JXLEncoderTests/Fixtures/ac_context.bin` | `genctx ac_context.bin` | unrecorded |
| `genprefix.cc` | `Tests/JXLEncoderTests/Fixtures/prefix_codes.txt` | `genprefix > prefix_codes.txt` | unrecorded |
| `gentokens.cc` | Expected values inline in `Tests/JXLEncoderTests/EntropyTests.swift` | `gentokens` | unrecorded |
| `gentree.cc` | `Tests/JXLEncoderTests/Fixtures/context_tree.txt` | `gentree > context_tree.txt` | unrecorded |
