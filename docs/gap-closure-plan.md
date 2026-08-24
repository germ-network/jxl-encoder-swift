# Retargeting the port to full libjxl at a named configuration (issue #2)

Plan of record. The port's reference changes from libjxl-tiny to **full
libjxl, implemented incrementally as a ladder of exact, reproducible command
lines** — `cjxl -e 4`, then `-e 5`, and so on. Everything this encoder emits
should converge to what the current rung's command emits; every stage where
we differ, the named command is right and this is a bug. No feature is
chosen by our own cost/benefit ranking, and no rung is chosen by comparison
to what this project shipped before — each rung is exactly what that `-e N`
invocation does, nothing added, nothing forced on. The implementation
surface grows rung by rung toward full libjxl; there is no fixed stopping
point.

## Why a named configuration

libjxl-tiny is itself a hybrid of full libjxl's speed tiers: 8×8-only
blocks (matching effort ≤4), a real adaptive-quant field (a ≥e5 feature —
e4 uses a uniform field), and prefix codes (which cjxl's VarDCT path never
emits at any effort). No `cjxl` invocation reproduces it. Continuing to
extend tiny feature-by-feature, ranked by measured payoff, would compound
that into a third codebase matching neither upstream — with no reference
left to instrument when output diverges. A named configuration keeps the
discipline that found every real bug in this project: when in doubt, run
the reference command, instrument it, and diff.

## The named target — rung 1

```
cjxl <input> <output>.jxl -d <distance> -e 4 --container=0
```

pinned at cjxl v0.12.x, plus `-j 1` for JPEG input (the recompression
path). **No forced flags.** Every setting `cjxl -e 4` picks by default is
what this rung implements, including gaborish and EPF defaulting off —
confirmed at the source: `SpeedTier::kCheetah` (= e4) is the tier
`AcStrategyHeuristics::ProcessRect` uses for DCT8-only fill, and gaborish
only turns on by default starting at `kHare` (e5), per `common.h`'s tier
comments. e4 is not chosen because of how it compares to anything this
project shipped before — that comparison caused real diversions during
Phase A (a filter-flag decision driven by "does this beat e7", not by what
e4 actually does) and is dropped as a criterion. e4 is chosen because it is
the simplest rung to reach first:

- **e1–e4 are DCT8-only.** `AcStrategyHeuristics::ProcessRect` fills the
  whole strategy image with DCT8 at `speed_tier >= kCheetah` (= e4). The
  existing 8×8-only core is a *correct implementation choice* for this
  rung, not a divergence.
- **The transcode effort ladder plateaus by e3**, so e4 loses nothing
  there (456,104 bytes at e3 vs 456,100 at e7 on the reference JPEG;
  verified at Phase A — e4 lands exactly on the plateau).
- **e4 excludes the expensive tail** — patches/dots/splines (e7 defaults),
  error diffusion (e6), AC-strategy search and the adaptive quant field
  (e5), gaborish/EPF (e5 defaults), and the butteraugli iteration loops
  (e8+) — by configuration, not by our judgment. Every one of those is a
  later rung; see "Growing past e4" below.

For reference only, not as a gate — measured on the corpus (2026-08-08,
d=1.0, ssimulacra2 / bytes), plain e4 against what jxl-coder shipped:

| image | e4 (this rung) | e7 (old jxl-coder default) | ours today |
|---|---|---|---|
| hopper | 89.82 / 10,307 | 90.63 / 10,002 | 82.70 / 8,413 |
| macan | 85.17 / 44,913 | 83.50 / 41,862 | 76.94 / 33,303 |
| bliznaca | 88.21 / 40,888 | 88.76 / 40,711 | 83.32 / 37,644 |

## What the measurements overturned (2026-08-08)

Recorded because the plan's shape depends on them:

- **Variable block sizes are not the smooth-content gap.** The 1024×1024
  gradient: ours 17,165 bytes; cjxl e4 — DCT8-only, same as us — 8,214;
  e7 with full block search 7,809. The 2.1× gap on smooth content is the
  entropy layer, not transforms. (An earlier inference in issue #2 blamed
  block sizes; it is wrong, and block sizes are now out of scope entirely.)
- **The transcode gap is pure entropy layer.** cjxl `-j 1` effort ladder:
  e1 = 482,165, e3 = 456,104, e7 = 456,100 vs ours 539,619 on a 546,797
  source. CfL ablation moved 0–0.5%. Even minimum-effort ANS beats our
  optimized prefix codes by 10.6%; our shipped transcode saves only 1.3%
  against the source JPEG.
- **Our quality deficit is substantially rate calibration.** At the same
  nominal distance we emit 9–35% fewer bytes than e4 and score 5–8 points
  lower — tiny operates at a lower point on the rate-distortion curve at
  equal `d`. e4 achieves its quality with a *uniform* quant field
  (`q = 0.79/d`), which tiny's adaptive-quant field replaces — so aligning
  with e4 likely means *deleting* AdaptiveQuant, not improving it.
  Confirmed by a matched-size check in Phase A before deletion.

## Phase A — pin the target and bound the work (no porting)

- A1. Filter-flag sweep: e4 × {gaborish on/off} × {epf 0–3} on the corpus,
  ssimulacra2 + bytes. Output: confirm what e4's real defaults are and
  what they cost, so rung 1 implements them exactly rather than by guess.
- A2. Matched-size RD check: our encoder at reduced `d` until size matches
  e4's per image; compare ssimulacra2. Confirms (or refutes) the
  rate-calibration reading and the AdaptiveQuant deletion.
- A3. Shannon-bound instrumentation on our clustered histograms: splits
  entropy gap into coder loss (prefix vs bound) and context-model loss
  (bound vs e4 actual); sets Phase B's size-corridor threshold.
- A4. Transcode e4 plateau verification; corpus regeneration script
  committed under `Reference/` (the measurement corpus lives in ephemeral
  scratch today and has already been wiped once).

## Phase A results (2026-08-08)

All four steps ran.

**A1 — confirms e4's real defaults are gaborish off, EPF irrelevant.**
Across the full gaborish × epf 0–3 grid on six corpus images: the epf
setting moved size by ≤4 bytes and ssimulacra2 by ≤0.3 regardless of
gaborish — noise, and consistent with EPF's sigma field being driven by
the quant field, which is uniform at e4. Gaborish is the whole filter
effect: +1.0 to +3.1 points for +7–31% size when forced on. Neither is
part of rung 1 — `cjxl -e 4` unmodified doesn't enable them, so this port
doesn't either. (The comparison to e7's quality that earlier drove a
should-we-force-gaborish debate is recorded above as reference data only;
it is not why gaborish is off here — it's off because e4 is off.)

**A2 — calibration is real but insufficient.** Encoding our RD curve
(d 1.0 → 0.4) and reading it at e4's size per image: still 1.8–3.5 points
below e4 at matched bytes on every photo. The gradient is categorical —
our size floor is ~16–17 KB at any distance vs e4's 8.2 KB. The deficit at
matched size is the entropy layer showing up on the quality axis: bits
spent on coding overhead are bits not spent on signal. Consequence: the
AdaptiveQuant deletion cannot be judged until after Phase B — the
quant-field comparison is confounded until the entropy layer is fixed.
Decision deferred to a post-B re-measure, not abandoned.

**A3 — the gap is modeling more than coding.** Instrumented split
(`jxlencode --entropy-report`), on the 4:2:0 transcode's 83.5 KB gap:

| component | share |
|---|---|
| prefix coder vs Shannon bound, current clustering | ~11 KB (2–3%) |
| clustering ceiling — tiny stages tokens through its static tables' 8 buckets; clustering the full context space at libjxl's limit of 128 yields 53 AC clusters | ~42 KB (10.9%) |
| residual: libjxl's richer context definitions, coefficient reordering, DC modular modeling, signaling | ~30 KB |

"Port the ANS serializer behind the existing seam" is therefore *not
sufficient*: Phase B must also cluster the full context space (replacing
the staged-bucket re-clustering inherited from tiny) and port libjxl's
context assignment for the transcode. Pixel-path DC on smooth content is
the one place the coder itself dominates (29% coder loss on the gradient's
modular DC — prefix's whole-bit floor on skewed distributions).

Instrumentation landed as emission-neutral changes, verified by the
byte-exact suite: staging now retains original token contexts (maps
compose identically at write-out), and `EntropyDiagnostics` +
`jxlencode --entropy-report` produce the split on demand.

**A4 — transcode e4 = e3 = the plateau** (456,104 / 568,375 bytes),
so `-e 4` serves both paths. Corpus regeneration is committed as
`Reference/make_corpus.sh`.

## Phase B — entropy back-end (both paths benefit)

Port from full libjxl, in dependency order (scope updated by A3 — the
serializer alone recovers only ~11 KB of the 83.5 KB transcode gap):

- [x] Full-context-space clustering at libjxl's limit of 128, replacing
  the staged-bucket re-clustering inherited from tiny's static tables —
  the single largest measured component. **Landed 2026-08-08** — see
  "Progress" below; recovered ~41–56 KB of the 83.5 KB transcode gap
  measured at Phase A.
- [x] libjxl's adaptive context assignment for transcoded JPEG (block
  context map). **Landed 2026-08-08** — see "Landed" below. Recovers only
  ~1.1–2.3 KB, far less than originally estimated; most of the remaining
  gap is elsewhere in the bundle this item's estimate came from.
- [ ] ANS serializer: `enc_ans.cc` table build, alias table, reverse-order
  stream writer. **Built 2026-08-08, not yet activated — see "ANS: built,
  gated off pending a bug" below.**
- Histogram clustering drift-check: our `HistogramCluster` (from tiny)
  against `enc_cluster.cc` (372 lines) at e4 settings.
- Coefficient reordering, which e4 enables: `enc_coeff_order.cc` (334) +
  `coeff_order.cc` (158) — now the most likely holder of the remaining
  transcode gap; re-attribute against real measurement once it lands,
  not against the pre-correction estimate.

The existing tokenization/context-map/hybrid-uint machinery is shared by
both back-ends in libjxl's own architecture (`use_prefix_code` per
section), so this is a new serializer behind an existing seam. The prefix
serializer is deleted when the corridor gate passes — the named target
never emits it, and keeping it would be preserving tiny through the back
door.

Gates: djxl decodes everything; JPEG transcode stays coefficient-exact vs
the source's dumped coefficients (existing gate); ImageIO decodes
everything (existing CI); transcode size within the A3-derived corridor of
the named command (expected ≤3%); pixel-path decoded pixels unchanged
(serialization cannot alter them — assert it).

### Progress: full-context clustering landed (2026-08-08)

Shipped ahead of the ANS serializer, since it needed none of the C++ port:
`SectionOptimizer.optimize` clustered from histograms pre-bucketed through
the base code's static context map (≤8 buckets) before ever running
`HistogramCluster.cluster`. That pre-bucketing is a faithful port of
tiny's actual behavior — confirmed at the source
(`libjxl-tiny/encoder/enc_frame.cc`'s `OptimizeSections` builds histograms
sized to `code->num_prefix_codes`, and `ClusterHistograms`' `kClustersLimit
= 8` is hardcoded — not a simplification our port introduced, tiny's real
optimizer has the same ceiling). It is not full libjxl's behavior:
`enc_context_map.h`'s `kClustersLimit = 128`, and full libjxl clusters the
raw token contexts directly.

Changed `optimize` to build histograms over the full raw context space
(`baseCode.contextCount` — 1980 for AC, 45 for DC) and cluster at limit
128; `contextMap` then spans the full space directly, so the prior
base-code composition step is gone. Emission-neutral for every existing
fixture (all 191 tests across both suites still pass unchanged) because
none reaches a scale where more than 8 natural clusters would ever form —
consistent with the divergence only showing up at 1024px+ in Phase A/the
original gap measurement, never at the ≤600px scale the byte-exact corpus
covers.

Measured impact, matching A3's ~42 KB / 10.9% estimate almost exactly:

| corpus image | before | after | Δ |
|---|---|---|---|
| recomp_420 (transcode) | 539,619 | 498,411 | −7.6%, closes 49% of the gap to the e4/e7 plateau (456,104) |
| recomp_444 (transcode) | 675,702 | 624,139 | −7.6%, closes 48% of the gap to plateau (568,375) |
| flower | 477,792 | 438,987 | −8.1% |
| gradient | 17,165 | 16,068 | −6.4% |
| hopper | 8,413 | 8,014 | −4.7% |
| macan | 33,303 | 31,811 | −4.5% |

Gates run: djxl decodes every output; decoded pixels' ssimulacra2 against
the corpus source is unchanged to the measured decimal on every image
checked (gradient, hopper, macan, flower) — confirms serialization altered
nothing but bits spent, as required.

Remaining transcode gap (~42–56 KB) is the context-assignment item still
queued below — libjxl's block-context map for JPEG transcode, not just
wider clustering of ours.

### Scoped: JPEG-transcode block context map (2026-08-08)

Larger than the plan's original one-line estimate. Traced at the source
(`enc_frame.cc`'s `ComputeJPEGTranscodingData`, ~1071–1116): full libjxl
buckets each block into up to 8 luma-DC-value quantiles
(`num_thresholds = clamp(log2(total_dc_luma) − log2(Σ quant-table values)
− 7, 1, 7)`, walking the DC histogram to place thresholds at even
population splits), then derives a per-block **AC context category** from
{channel × AC-strategy-order × DC-bucket} — up to 16 categories, signaled
per image via a dedicated wire section (`EncodeBlockCtxMap`, called
separately from the entropy code's own context-map writer at
`enc_frame.cc:1246`).

This is *not* how DC values themselves get coded — that stays through the
modular DC image (`AddVarDCTDC(..., jpeg_transcode: true)`), architecture
unchanged from what tiny already does and our port already matches. It's
an additional, adaptive input to **AC** context selection, on top of what
`ACContext.blockContext(channel:acStrategyCode:)` already computes.

The gap to the plan's original estimate: our port has never emitted a
non-trivial block context map at all. `ACContext`'s `numBlockCategories =
4` is a fixed constant (tiny's design — channel-only, no per-image
adaptation), and nothing in `Sources/JXLEncoder` writes the wire section
that would signal something richer. So this item is two things bundled
together, not one: (1) the DC-threshold algorithm above, JPEG-transcode
specific, and (2) a wire-format section our port has zero prior
implementation of — decoders (ImageIO, djxl) already support it, since
it's spec-required and every other real encoder emits it; only our
encoder side is missing. Sizing (2) needs a source read of
`EncodeBlockCtxMap`'s actual serialization before estimating effort
honestly — not done yet.

**Sized (2026-08-08).** `enc_context_map.cc`'s `EncodeBlockCtxMap` (36
lines) + `EncodeContextMap` (105 lines) is smaller than feared: the
general routine (simple/full fallback, entropy-coded small-int array) is
close to what `EntropyCodeWriter.writeContextMap` already does for the
token-level context map — this is the same wire concept applied to a
different array, not a new one. The formula is now fully pinned:
`num_thresholds = clamp(⌈log₂(total_dc_luma)⌉ − ⌈log₂(qt[1..5] sum)⌉ − 7,
1, 7)`, where `qt[1..5]` are the JPEG's own luma quant table's first five
transposed AC entries — data our parser already extracts. Thresholds are
placed at even population splits of the luma DC value histogram; chroma
channels get zero thresholds of their own and derive context from the
co-located luma bucket (`i/2`). `kNumOrders = 13` (AC-strategy-order
buckets) means the transmitted `ctx_map` array is sized `3 × 13 ×
num_dc_ctxs`, but transcode is always DCT8 (order 0), so only ~24 of up to
~312 entries are ever meaningful — the array shape must still match what
the decoder derives from the signaled counts, so the padding is
transmitted (cheaply, given move-to-front + entropy coding), not
implementation complexity.

The real cost is architectural, not the wire section: **this requires a
global pre-pass**. `ACGroupEncoder.encodeJPEG` currently extracts each
block's DC value and tokenizes its AC coefficients in the same pass, group
by group (`Sources/JXLEncoder/ACGroupEncoder.swift:290`-ish). But
threshold placement needs the *whole image's* luma DC histogram before any
block can be assigned a bucket — a genuine two-pass requirement the
current single-pass group driver doesn't have. Scope: a DC-only pre-pass
over every AC group (reusing the existing DC-extraction logic, skipping
tokenization) to build the histogram and compute thresholds, then the
existing group pass looks up each block's bucket during tokenization.

### Landed (2026-08-08)

Implemented as designed: a parallel module (`JPEGBlockContextMap.swift`,
`AdaptiveACContext`) rather than parameterizing `ACContext` — the pixel
path and the JPEG static-table path (`optimizeCodes: false`, still
actively tested) are byte-for-byte untouched; the adaptive scheme only
applies when `optimizeCodes: true`. `EntropyCodeWriter.writeContextMap`
was refactored (pure signature change, verified behavior-preserving) to
share its array-writing machinery with the new block-context-map section,
matching how full libjxl's own `EncodeContextMap` serves both callers.

Two source-verification catches worth recording, since both would have
been silent wrong-pixel bugs if assumed instead of checked:
`BlockCtxMap::Context`'s channel-to-slot permutation (`c<2 ? c^1 : 2`) —
my first draft indexed by raw channel — and confirming every channel's
context at a block position reads the *same* luma-derived DC bucket
(`row_qdc[bx]`, indexed by the full-resolution position, not each
channel's own subsampled one).

Gated per the plan: unit tests for the threshold-placement algorithm in
isolation (5 hand-computed cases, including the `>7` clamp and the exact
channel-slot permutation) before any wiring; full suite green throughout,
including the two `optimizeCodes: false` tests that would have caught a
leak into the static path; a new permanent test
(`blockContextMapIsAdaptive`) asserting the map is genuinely non-trivial
on the existing 2200px checkerboard fixture — pixel fidelity alone
wouldn't have caught a regression to a degenerate map, since a trivial
one still decodes correctly, just larger.

**Measured impact is much smaller than A3's estimate — and that's a
correction to record, not a bug.** A3 attributed ~30 KB of the 83.5 KB
transcode gap to "libjxl's richer context definitions, coefficient
reordering, DC modular modeling, signaling" as one bundled residual. This
item is confirmed working (real photos: 4 thresholds, 11 categories;
checkerboard2200: 6 thresholds, 15 categories — verified non-trivial, not
a no-op) but recovers only ~1.1–2.3 KB on the two real transcodes
(497,273 / 621,867 bytes, down from 498,411 / 624,139). The bundled
estimate over-attributed to this specific piece; coefficient reordering
(still unstarted, below) is now the more likely holder of most of the
remaining ~40–54 KB, not block-context-map. Re-attribute once reordering
lands, rather than assume.

### ANS: landed (2026-08-08, fixed 2026-08-24)

Traced fully to source before implementing: `InitAliasTable`
(`ans_common.cc`, ~110 lines, ported verbatim — zero tolerance, since it's
never transmitted and both sides must reconstruct it identically),
`ANSBuildInfoTable` (inverts it into a per-symbol `reverseMap`),
`ANSCoder::PutSymbol` (the rANS state recursion — plain division
substituted for the reciprocal-multiplication trick, which is a pure
perf optimization equivalent to the division it replaces), and
`WriteTokens`' reverse-order encode loop with its bit-chunk accumulator
(matches our own `BitWriter.maxBitsPerCall = 56`, the same constraint
libjxl's own writer has, for the same shift-overflow reason).

Two deliberate simplifications, both justified by the plan's own
non-goals (byte-exactness against cjxl is explicitly not a gate):
`RebalanceHistogram`'s greedy bin-by-bin size search over a precomputed
12x4096 allowed-counts table is replaced with standard largest-remainder
rounding to full precision (real libjxl's own `shift = ANS_LOG_TAB_SIZE`
case, not an invented one — larger headers, identical wire *shape*).
`ANSHistogramWriter` ports `Encode`'s RLE + static-Huffman bit-width
signaling faithfully, since that part *is* wire-format-required, not a
size optimization — `omit_pos` in particular is load-bearing (the
decoder identifies the omitted symbol by which has the largest
transmitted bit-width, not by an explicit flag).

Scoped to AC sections only, not DC: `DCGroupEncoder.write` interleaves
raw header bits with tokens (`writeRaw`, then tokens, then `writeRaw`
again, then more tokens), which ANS cannot split mid-stream since it
needs a section's whole token list up front to encode in reverse. Grepped
confirmed AC sections are pure token streams with no such interleaving.
This also happens to align with where the size win lives — DC's own
coder-loss was 2-3%, AC's 10.9%, per Phase A's split.

Wired end to end — `EntropyCode` gained an `ansInfoTables` field,
`EntropyCodeWriter.write` branches on it (`use_prefix_code` bit + either
path), `SectionWriter` gained `flushANS`, `SectionOptimizer.optimize`
gained `allowANS` (only ever true for the AC call sites) and real
libjxl's own `total_tokens < 100` threshold for preferring prefix
(`enc_ans.cc`) — small sections stay prefix-coded exactly as before,
unaffected by ANS being available at all.

**Result: decode succeeds but produces wrong pixels (mean error ~200,
against a <2.5 gate) on every case where ANS actually engaged** —
consistent, not intermittent, across every fixture tested. The alias
table is independently verified (hand-traced 75/25 rebalancing case,
full-partition invariant over a 5-symbol distribution, both passing as
unit tests with no pipeline involved) and the static-table
(`optimizeCodes: false`) and small-fixture prefix paths remain fully
green throughout, which together isolate the bug to the histogram
signaling or the token writer specifically, not a broader regression —
but the specific defect was not found by re-reading against source a
second and third time.

**Found the defect by diffing `EncodeUintConfig` (`enc_ans.cc`) line by
line against `PrefixCodeWriter.writeUintConfigs`**, not by the suggested
round-trip diagnostic — the histogram signaling and token writer were both
already correct. The bug was one level up: `writeUintConfigs` hardcoded
the *bit widths* used to signal each histogram's hybrid-uint config
(`write(4, splitExponent)`, `write(3, msbInToken)`, `write(2, lsbInToken)`)
as constants. Those widths are only correct for the prefix path, where
`log_alpha_size` is pinned to `PREFIX_MAX_BITS = 15`
(`CeilLog2Nonzero(15+1) = 4`, etc.). Real libjxl derives them from
whatever `log_alpha_size` the code actually uses —
`CeilLog2Nonzero(log_alpha_size + 1)` and so on — and ANS signals a much
narrower `log_alpha_size` (6, for this port's fixed 64-symbol alphabet:
`CeilLog2Nonzero(6+1) = 3`, one bit short of the hardcoded value). Every
ANS-coded histogram's config header was misaligned by one bit, which
desynced every bit read after it — the histogram signaling and the entire
token stream — while still parsing as *something*, hence "decodes, wrong
pixels" rather than an outright failure. Fixed by giving
`writeUintConfigs` an explicit `logAlphaSize` parameter and computing the
three field widths from it (`ceilLog2Nonzero`, added next to the
existing `floorLog2Nonzero`); the prefix call site now passes
`prefixMaxBits = 15` explicitly instead of relying on hardcoded widths
that happened to match it.

**Verified**: full suite green (37 tests/6 suites), including the
49-case optimized-photo suite that round-trips through real `djxl` and
ImageIO at every distance. Independently re-verified outside the test
suite: all 6 real-photo corpus images (`bliznaca`, `flower`, `gradient`,
`hopper`, `macan`, `riaphoto`) encode with ANS engaged (2–46 clusters,
coder-loss now 1.7–15.2% vs. Phase A's 10.9% AC estimate — the low end is
where ANS actually helps; `gradient`'s single-cluster AC histogram has no
loss to speak of), decode cleanly through the debug `djxl` build
("Decoded to pixels"), and land within 0.5–2.6 mean absolute error per
channel against source (max per-channel error 7–75) — ordinary lossy
error at distance 1.0, nothing like the ~200 mean error the bug produced.
Size impact on this corpus is modest (flower −2.6%, macan −3.7%,
bliznaca/hopper/riaphoto −0.8 to −1.8%, gradient +0.4%), consistent with
the largest-remainder-rounding simplification documented above trading
some of libjxl's own header-size optimization away for simplicity.

`allowANS: true` at all three `SectionOptimizer.optimize` AC call sites
in `Encoder.swift`.

## Phase C — pixel-path alignment to the named command

In order: quant calibration (uniform field `0.79/d`, global scale mapping —
including the AdaptiveQuant deletion if A2 confirms), CfL-default
alignment check (e4 uses the default correlation map; we already emit
defaults — verify byte-level agreement). Gaborish and EPF are not rung-1
work — they are off by default at e4 (A1), so there is nothing to port
until a later rung enables them (see "Growing past e4").

Gate per stage: corpus ssimulacra2 and size move *toward* the named
command's numbers, decode gates pass. End-state gate: within the corridor
of the named command on every corpus image, both axes.

## Phase D — close the loop

Rerun germDM-ios-refresh#661's tables against the named command. Un-drafting
#661 is decided on those numbers.

## API surface

The public entry points (`distance:` on `JXLEncoderApple.encode`) are
unaffected — distance stays continuous, chosen by the caller, and is
orthogonal to which rung is implemented. Effort is not: it becomes a
closed enum, one case per rung actually implemented, each documented as
the literal `cjxl` invocation it reproduces:

```swift
public enum Effort: Int, Sendable {
    /// ≡ `cjxl -e 4` (default gaborish/EPF: off)
    case e4 = 4
}
```

No range validation, no clamping — an effort not yet implemented is a
compile error (the case doesn't exist) or, for a caller passing a
non-static value, a thrown `unsupportedEffort` naming what's supported.
Silently substituting a lower rung for a requested one hides a real budget
mismatch from the caller; this project's repeated failure mode has been
believing an unverified number, not a caller getting an explicit error.
Adding `case e5` later is purely additive.

## Growing past e4

Rung 1 is not a destination. Once e4's gates pass, the next rung is e5 —
its own named command (`cjxl -e 5 ...`), its own phased plan following this
same shape (bound the work, port, gate, close the loop), and its own entry
in this document. e5 is where the adaptive quant field, gaborish, EPF, and
richer AC-strategy heuristics actually enter scope; e6 adds error
diffusion; e7 adds patches/dots/splines. Each rung is implemented because
it's the next `-e N`, not because it beats a prior rung's output — that
framing produced the gaborish detour in Phase A and is retired as a
decision criterion for good. The growth path is the implementation surface
converging on full libjxl, rung by rung, for as long as it's worth the
engineering cost — not a fixed stopping point chosen now.

## Interim honesty

While B and C land, the tree is transitionally a hybrid (ANS with tiny's
quant calibration, etc.). That is unavoidable mid-port and is not the end
state; the end state is the named command, and stages land in an order
that keeps every intermediate decodable and gated. Byte-exact-vs-tiny gates
are retired stage by stage as each stage is retargeted, not wholesale.

## Scope-document changes (land with Phase B)

README scope and NOTICE.md currently name libjxl-tiny alone; both change to
name full libjxl at the pinned configuration as the reference, with tiny
acknowledged as the port's origin. CONTRIBUTING already names full libjxl
for the recompression path. Upstream license text is byte-identical between
the two repos (verified by diff, 2026-08-08); LICENSE is unchanged. The
"no novel contributions" statement survives — implementing a subset of a
named upstream configuration invents nothing.

## Non-goals (for this rung)

Everything e4 does not do — variable block sizes and AC-strategy search,
the adaptive quant field, error diffusion, patches/dots/splines, gaborish,
EPF, butteraugli iteration — is out of scope for *this* rung, not excluded
from the project. Each is a later rung's work item; see "Growing past e4."
Standing non-goals regardless of rung: progressive passes, animation, HDR,
modular mode beyond the existing DC/alpha uses, and byte-exactness against
cjxl itself (full libjxl is SIMD/threading-nondeterministic — gates are
decode-exactness, corridors, and metrics, at every rung).
