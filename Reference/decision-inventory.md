# Decision inventory schema

`decision-inventory.tsv` records, for every production encoder decision in this
package, which upstream libjxl function and configuration it translates and how
faithfully. Other work cites rows by `id`. Valid output or a smaller file never
establishes that a row is faithful; only the upstream function and configuration
do.

The reference is full libjxl only:

```
libjxl@a7a9c787341cf703dede03c2009fa460cae5e5df   (tag v0.12.0)
```

The target configuration is `cjxl -d <D> -e 4 --container=0` for pixels
(`SpeedTier::kCheetah`, since `-e N` maps to `SpeedTier(10 - N)`) and the same with
`-j 1` for lossless JPEG recompression.

`DecisionInventoryTests` (in `JXLEncoderTests`) enforces every rule below.

## Files

| file | contents |
|---|---|
| `decision-inventory.tsv` | one row per decision, columns below |
| `decision-inventory-exempt.tsv` | Swift source files that hold no production decision, with the reason |

Both are UTF-8, tab-separated, with one header line, LF line endings and no
quoting. Fields never contain a tab, newline or carriage return. Every field is
non-empty, and `-` means "none" where a column allows it.

## Columns of `decision-inventory.tsv`

| # | column | content |
|---|---|---|
| 1 | `id` | Stable id, `^[A-Z]{2,4}-[0-9]{2,3}$`; the prefix names the area (table below). Never renumbered and never reused. A row whose decision disappears from the code is deleted, and its id stays retired. |
| 2 | `swift_file` | Path from the package root, e.g. `Sources/JXLEncoder/ANSCoder.swift`: an existing `.swift` file under `Sources/`. |
| 3 | `swift_symbol` | Type or function that makes the decision, e.g. `ANSHistogramNormalizer.normalize`. `(absent)` when Swift lacks an upstream decision that applies at the target configuration; `swift_file` is then the file where it belongs, the row is `original`, and `upstream_function` names the missing function. A restriction upstream shares at that configuration (e.g. DCT8-only at `-e 4`) is not absent: it gets a row on the Swift symbol that hard-codes it. Never `-`. |
| 4 | `decision` | What is decided, in one line. Never `-`. |
| 5 | `path` | Encode path the decision affects: `pixel`, `jpeg`, `both`, `static` (the `optimizeCodes: false` path) or `platform` (the Apple shim). |
| 6 | `upstream` | `libjxl@a7a9c787341cf703dede03c2009fa460cae5e5df`, or `-` when there is no upstream counterpart. libjxl-tiny is never cited here. |
| 7 | `upstream_function` | `lib/jxl/<file>:<Function>` (or `tools/<file>:<Function>` for cjxl flag handling), split at the first colon so the function may be qualified, e.g. `lib/jxl/enc_ans.cc:ComputeBest` or `lib/jxl/enc_ans.h:ANSCoder::PutSymbol`, of the full-libjxl function the decision translates or must be retargeted to. `-` exactly when `upstream` is `-`. |
| 8 | `config` | The upstream configuration that selects that branch, e.g. `-e 4 kCheetah; HistogramParams.ans_histogram_strategy=kApproximate`, or for JPEG `-e 4 -j 1`. `-` exactly when `upstream` is `-`. |
| 9 | `classification` | One of the four classes below. |
| 10 | `verification` | `diffed`, `cited` or `assumed` (below). |
| 11 | `evidence` | Space-separated locations backing the classification (a line may be a range, `:12-20`): the row's own `<swift_file>:<line>` at the audited commit (omitted only for `(absent)`), and, when `upstream` is pinned, at least one `lib/…:<line>` or `tools/…:<line>` at the pin. `inherited-tiny` rows also name the libjxl-tiny source as `tiny:<file>:<function>` (tiny is unpinned). Never `-`. Output size, bits per pixel or successful decoding are never evidence. |
| 12 | `replacement` | Comma-separated (no spaces) Linear issue ids that replace or verify this decision, or `-`. Only issues in the checker's `replacementIssues` list are accepted: GER-3386, GER-3387, GER-3388, GER-3389, GER-3392, plus any issue filed for this audit and added to that list. |
| 13 | `notes` | Free text, or `-`. On `adapted` rows, the equivalence argument (never `-`). |

## Classification

| value | meaning |
|---|---|
| `faithful` | Translates the cited upstream function under the cited config, with no behavioural difference. |
| `adapted` | Differs in form for memory safety or Swift arithmetic (bounds-checked buffers, integer widths, division in place of a reciprocal) and is claimed equivalent in output; `notes` says why. |
| `inherited-tiny` | Still follows libjxl-tiny where full libjxl e4 differs; awaiting retargeting (D-3). |
| `original` | Local implementation or policy with no faithful upstream source: a replacement, simplification, omission (`(absent)`) or platform glue. |

## Verification

| value | meaning |
|---|---|
| `diffed` | The Swift was read side by side against the cited upstream function and config. |
| `cited` | The upstream function and config were identified and opened, but not compared line by line. |
| `assumed` | Classified from lineage (for example a table libjxl-tiny shares with libjxl) without opening the upstream code. |

## Rules

1. Each file's header line is exactly its column names, in order. Every line has that many non-empty fields and no carriage return.
2. Ids match the pattern, are unique, and use the prefix the table below assigns to the row's `swift_file`.
3. `classification`, `verification` and `path` take only the listed values.
4. `upstream` is the pinned revision or `-`; `-` only with `original`. `upstream_function` and `config` are `-` exactly when `upstream` is.
5. Provenance: `swift_symbol`, `decision` and `evidence` are never `-`; `evidence` holds the locations column 11 requires; `upstream_function`, when not `-`, is `(lib|tools)/<path>:<Function>`.
6. `(absent)` rows are `original` with a pinned upstream.
7. `inherited-tiny` rows name a `tiny:` source in `evidence`; `adapted` rows argue equivalence in `notes`.
8. `replacement` is `-` only when the row needs no further work: `faithful` or `adapted`, with `diffed`. Every other row (every deviation, and every claim not compared line by line) names at least one accepted issue. A `faithful` or `adapted` row that is `cited` or `assumed` names GER-3392 as its verifier, alongside any area issue. `inherited-tiny` and `original` rows name an area issue (not GER-3392 alone), since they need replacing, not only verifying.
9. Every `swift_file` (in either file) is an existing `.swift` file under `Sources/`.
10. Coverage: every `.swift` file under `Sources/` has at least one row or an exemption, never both; no file is exempted twice. The exemptions are exactly the agreed set (`DecisionInventory.agreedExemptions`); changing it is a reviewed decision. A file both inventoried and exempt is reported with rules 1–9; a file with neither is reported per source group (`SourceGroup`).

The checker proves shape, not completeness of rows within a file: that one row per decision exists is established by review against the audited code.

## Columns of `decision-inventory-exempt.tsv`

| # | column | content |
|---|---|---|
| 1 | `swift_file` | Path from the package root. |
| 2 | `reason` | Why the file holds no production decision. |

## Id prefixes

| prefix | file |
|---|---|
| `AC` | ACContext.swift |
| `AG` | ACGroupEncoder.swift |
| `AH` | ANSHistogramWriter.swift |
| `AN` | ANSCoder.swift |
| `AQ` | AdaptiveQuantPipeline.swift |
| `AT` | ACTokenizer.swift |
| `AW` | ANSTokenWriter.swift |
| `BC` | JPEGBlockContextMap.swift |
| `BW` | BitWriter.swift |
| `CO` | CoeffOrder.swift |
| `CS` | ChromaSubsampling.swift |
| `CT` | ContextTree.swift |
| `DCT` | DCT.swift |
| `DG` | DCGroupEncoder.swift |
| `DP` | DistanceParams.swift |
| `DPR` | DCPredictor.swift |
| `EC` | EntropyCode.swift |
| `ENC` | Encoder.swift |
| `EW` | EntropyCodeWriter.swift |
| `FA` | FrameAssembly.swift |
| `FM` | FastMath.swift |
| `FC` | Float16Coder.swift |
| `GE` | Geometry.swift |
| `HC` | HistogramCluster.swift |
| `HT` | HuffmanTree.swift |
| `IH` | ImageHeader.swift |
| `JH` | JPEGHuffman.swift |
| `JO` | JPEGOrientation.swift |
| `JP` | JPEGParser.swift |
| `JR` | JPEGRecompression.swift |
| `JT` | JPEGTranscode.swift |
| `PB` | PlaneBuffer.swift |
| `PC` | PrefixCodeWriter.swift |
| `QM` | QuantMatrices.swift |
| `QR` | QuantizeRoundtrip.swift |
| `QW` | QuantMatrixWriter.swift |
| `QZ` | Quantizer.swift |
| `RE` | ReciprocalEstimate.swift |
| `SE` | StaticEntropyCodes.swift |
| `SR` | SRGBTransfer.swift |
| `SW` | SectionWriter.swift |
| `TK` | Token.swift |
| `XYB` | XYB.swift |
| `APL` | Sources/JXLEncoderApple/JXLEncoderApple.swift |

A new source file gets a new prefix added to this table.
