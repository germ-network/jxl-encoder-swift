# Pinned Reference Build (libjxl v0.12.0)

This directory defines and builds the reproducible reference libjxl binaries
and fixtures for JXLEncoder.

## Overview

JXLEncoder gates its JPEG XL bitstreams, entropy coding, and JPEG transcode
against the upstream libjxl reference implementation pinned at:
- **Repository**: `https://github.com/libjxl/libjxl.git`
- **Tag**: `v0.12.0`
- **Commit**: `a7a9c787341cf703dede03c2009fa460cae5e5df`

The complete pin definition, including exact submodule revisions, CMake flags,
and external tool dependencies, is recorded in [`Reference/libjxl.pin`](libjxl.pin).

---

## Prerequisites

- **CMake**: version 3.16 or later.
- **C++ Compiler**: Apple Clang or GCC with C++17 support.
- **Git**: version 2.20 or later.
- **Disk Space**: approximately 3 GB free for the build tree (`df -h`).
- **Required Libraries**:
  - `libjpeg-turbo`: version `3.2.0` (matching `JPEG_TURBO_VERSION` in `libjxl.pin`).
  - `little-cms2` (`lcms2`)
  - `libpng`

  On macOS via Homebrew:
  ```bash
  brew install jpeg-turbo little-cms2 libpng
  ```

---

## Fetch, Pin-Check, and Build

### 1. Fetching the Pinned Source

Fetch the pinned libjxl checkout and required submodules (`highway`, `brotli`, `skcms`, `testdata`):

```bash
Reference/fetch-libjxl.sh [TARGET_DIR]
```

Default target directory is `$LIBJXL_DIR` if set, or `$HOME/tmp/automation/libjxl-v0.12.0`.
The script fetches the exact detached commit and submodules, then automatically runs
`Reference/pin-check.sh` on the checkout.

### 2. Checking Pin Drift

To verify an existing checkout against `Reference/libjxl.pin`:

```bash
Reference/pin-check.sh [DIR]
```

If the libjxl HEAD commit, submodule commits, or working tree state
diverge from the pin record, the script fails loudly with `PIN DRIFT` and
exits with code 1.

The pin and its manifest references are also verified by Swift Testing suites:
- `PinRecordTests`: verifies pin file syntax, submodule SHAs, and sha256 digests.
- `FixtureProvenanceTests`: verifies that all committed fixtures and tests match
  the pinned commit or legacy records.

### 3. Building Reference Binaries

To build the reference tools:

```bash
Reference/build.sh [DIR]
```

This builds three binaries and generates the revision report into `Reference/build/`:
- **`cjxl`** (Release): the reference encoder used for gap-closure and corridor tests (`cjxl -e 4`).
- **`djxl`** (Release): the release reference decoder.
- **`djxl-dbg`** (Debug): the debug reference decoder with assertion logging enabled.
- **`REVISION.txt`**: records the git commit, tag, date, compiler version, and build flags.

---

## Debug `djxl-dbg` Purpose

Release builds of libjxl compile out detailed error diagnostics. The debug
decoder `djxl-dbg` built by `Reference/build.sh` is compiled with
`-DCMAKE_BUILD_TYPE=Debug` so that internal `StatusMessage` logging is enabled.

When debugging decoder rejections against JXLEncoder bitstreams, `djxl-dbg`
prints the exact file, line number, and check that failed:

```bash
Reference/build/djxl-dbg output.jxl /tmp/out.png 2>&1 | grep FAILURE
# e.g., quant_weights.cc:431: JXL_FAILURE: Invalid mode
```

---

## Configuration Knobs and Tool Provenance

### `OPTIMIZE_CODE` is Tiny-Only

The `OPTIMIZE_CODE` preprocessor macro (`0` or `1`) is specific to legacy
libjxl-tiny (`Reference/legacy-tiny/`). Full libjxl does not expose this macro;
its analogue is encoder effort (`cjxl -e 4`). Per-gate configuration settings
and historical macros are cataloged in [`Reference/provenance.tsv`](provenance.tsv).

### `genrecip` is Host-arm64

`Reference/make_recip_fixture.sh` builds and runs `Reference/tools/genrecip.cc`
to produce `Tests/JXLEncoderTests/Fixtures/recip_estimate.bin`.

Because `genrecip.cc` captures the hardware `vrecpeq_f32` NEON reciprocal estimate
instruction, the script requires an `arm64` host (`arm64` or `aarch64`).

### JPEG Fixtures Require Pinned libjpeg-turbo 3.2.0

`Reference/make_jpeg_fixtures.sh` regenerates JPEG parser test fixtures and
coefficient dumps (`.coef`).

To guarantee byte-identical reproduction:
- `cjpeg -version` must report `3.2.0`.
- `$JPEG_PREFIX/include/jconfig.h` must define `LIBJPEG_TURBO_VERSION` as `3.2.0`.

Any version mismatch causes `make_jpeg_fixtures.sh` to abort.

## Internal reference harness

Run `Reference/build-harness.sh`, then `Reference/harness/test-harness.sh`.
The build adds the pinned checkout as a CMake subproject, links its internal
libraries, and writes all build output to `Reference/build/harness/`. It never
patches or writes into the checkout; pin-check runs before and after building.
`jxl-harness version` reports the pinned commit and dispatched Highway target.
The reference target is arm64 NEON, with NEON_BF16 disabled by the harness
CMake configuration so BF16-capable hosts use the same target.

The verified harness version reports
`libjxl=a7a9c787341cf703dede03c2009fa460cae5e5df` and `hwy=NEON`.
Highway is present in the pin's `third_party/highway/`; its
`hwy/ops/arm_neon-inl.h` supplies NEON's approximate reciprocal. The existing
`recip_estimate.bin` captures the host instruction; it is not a full-libjxl
quantization-bias fixture. Semantic and stage fixtures record their individual
SIMD targets and reproducible inputs in `Reference/provenance.tsv`.

`Reference/semantic-crosscheck.sh` sends actual Swift and native reference
codestreams through `FrameDecoder` layout parsing. It checks section bounds and
observed selectors for four-group and sixteen-group frames, then crops the
first 257 rows from the recorded 2057x521 pixel-lifecycle source and verifies
the eligible 2057x257 reference has 18 AC groups, two DC groups, two histogram
sets, and its observed selector partition. The script flips a recorded AC
selector bit and requires the changed stream to be rejected. This is separate
from semantic mutation checks, which still verify exact changed fields.

`Reference/entropy-stream-crosscheck.sh` regenerates the pinned upstream
receipts for the Swift-produced shared ANS and prefix code/stream fixtures and
checks malformed padding, stream-boundary, and final-ANS-state mutations.
`Reference/harness/test-harness.sh` runs this receipt gate after building the
harness. The Swift tests separately bind current `SectionWriter` output bytes
and bit counts to the same committed receipts.
