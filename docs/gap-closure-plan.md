# Retargeting the port to full libjxl at a named configuration (issue #2)

Plan of record. The port's reference changes from libjxl-tiny to **full
libjxl invoked as one exact, reproducible command line**. Everything this
encoder emits should converge to what that command emits; every stage where
we differ, the named command is right and this is a bug. No feature is
chosen by our own cost/benefit ranking — the configuration is chosen once,
here, and then implemented.

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

## The named target

```
cjxl <input> <output>.jxl -d <distance> -e 4 --container=0
```

pinned at cjxl v0.12.x, plus `-j 1` for JPEG input (the recompression
path), plus pixel-path filter flags (`--gaborish=1 --epf=<N>`) whose values
are fixed by Phase A's sweep and then become part of the named command.

Effort 4 is chosen on source and measurement evidence, not convenience:

- **e1–e4 are DCT8-only.** `AcStrategyHeuristics::ProcessRect` fills the
  whole strategy image with DCT8 at `speed_tier >= kCheetah` (= e4). The
  existing 8×8-only core is a *correct implementation choice* for this
  target, not a divergence.
- **e4 matches the app's old quality bar.** The bar is what jxl-coder
  shipped: cjxl e7 at d=1.0. Measured on the corpus (2026-08-08, d=1.0,
  ssimulacra2 / bytes):

  | image | e4 | e4 +gab +epf1 | e7 (old bar) | ours today |
  |---|---|---|---|---|
  | hopper | 89.82 / 10,307 | 92.22 / 12,187 | 90.63 / 10,002 | 82.70 / 8,413 |
  | macan | 85.17 / 44,913 | 88.25 / 58,849 | 83.50 / 41,862 | 76.94 / 33,303 |
  | bliznaca | 88.21 / 40,888 | 90.48 / 47,820 | 88.76 / 40,711 | 83.32 / 37,644 |

  Plain e4 sits within ~1 ssimulacra2 point of e7 at a few percent size
  premium; forcing Gaborish+EPF pushes quality *above* e7 on every photo at
  a 17–41% size premium. Whether the named command includes the filter
  flags is a size-vs-quality product decision (Phase A exit, Mark's call).
- **The transcode effort ladder plateaus by e3**, so e4 loses nothing
  there (456,104 bytes at e3 vs 456,100 at e7 on the reference JPEG;
  verify e4 lands on the plateau at Phase A — expected, cheap to check).
- **e4 excludes the expensive tail.** Patches/dots/splines (e7 defaults),
  error diffusion (e6), AC-strategy search and the adaptive quant field
  (e5), and the butteraugli iteration loops (e8+) are all out of scope by
  configuration, not by our judgment.

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
  ssimulacra2 + bytes. Output: the exact named command, chosen against the
  e7 bar. Decision on record in this file.
- A2. Matched-size RD check: our encoder at reduced `d` until size matches
  e4's per image; compare ssimulacra2. Confirms (or refutes) the
  rate-calibration reading and the AdaptiveQuant deletion.
- A3. Shannon-bound instrumentation on our clustered histograms: splits
  entropy gap into coder loss (prefix vs bound) and context-model loss
  (bound vs e4 actual); sets Phase B's size-corridor threshold.
- A4. Transcode e4 plateau verification; corpus regeneration script
  committed under `Reference/` (the measurement corpus lives in ephemeral
  scratch today and has already been wiped once).

## Phase B — entropy back-end (both paths benefit)

Port from full libjxl, in dependency order:

- ANS serializer: `enc_ans.cc` table build, alias table, reverse-order
  stream writer (~800–1,000 relevant lines of 1,388; prefix and LZ77
  portions excluded — verify LZ77 is off for our sections at e4).
- Histogram clustering drift-check: our `HistogramCluster` (from tiny)
  against `enc_cluster.cc` (372 lines) at e4 settings.
- Coefficient reordering, which e4 enables: `enc_coeff_order.cc` (334) +
  `coeff_order.cc` (158).

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

## Phase C — pixel-path alignment to the named command

In order: quant calibration (uniform field `0.79/d`, global scale mapping —
including the AdaptiveQuant deletion if A2 confirms), Gaborish
(`enc_gaborish.cc`, 74 lines — encoder-side inverse convolution plus
signaling), EPF signaling (at uniform quant the sigma field is constant —
small), CfL-default alignment check (e4 uses the default correlation map;
we already emit defaults — verify byte-level agreement).

Gate per stage: corpus ssimulacra2 and size move *toward* the named
command's numbers, decode gates pass. End-state gate: within the corridor
of the named command on every corpus image, both axes.

## Phase D — close the loop

Rerun germDM-ios-refresh#661's tables against the named command. Un-drafting
#661 is decided on those numbers.

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

## Non-goals

Everything e4 does not do: variable block sizes and AC-strategy search,
the adaptive quant field, error diffusion, patches/dots/splines,
butteraugli iteration, progressive passes, animation, HDR, modular mode
beyond the existing DC/alpha uses. Byte-exactness against cjxl (full
libjxl is SIMD/threading-nondeterministic; gates are decode-exactness,
corridors, and metrics). Effort levels other than 4.
