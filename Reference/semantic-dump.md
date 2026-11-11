# Semantic dump (I-3)

A semantic dump lists the encoder decisions a JPEG XL codestream carries, as
named integer and float fields. Two sides write one:

- **Reference:** `jxl-harness dump <file.jxl>` decodes any bare codestream with
  the pinned libjxl (`Reference/libjxl.pin`) and records what the decoder state
  holds. It is used on the pinned libjxl's own `-e 4` output to make the
  committed fixtures (`Tests/JXLEncoderTests/Fixtures/semantic/*.sem`), and on
  this package's output for the local cross-check.
- **Swift:** `SemanticDump(swiftDecisions:)` in the tests builds the same fields
  from the Swift encoder's own decisions, so CI (which has no libjxl) compares
  Swift against the fixtures.

Comparison catches a changed decision even when the file still decodes and
its size is unchanged. Whole-file byte equality is never required: upstream
SIMD and float differences make it the wrong test.

## Text format

UTF-8 with LF line endings. The first line is exactly `jxl-semantic-dump 1`.
Every other line is one field:

```
<name> <kind> <count> <value>…
```

- `name`: `<category>.<field>[.<qualifier>…]`, made of `[a-z0-9_.]`. The
  category is the harness dumper that owns the field (one source file,
  `Reference/harness/src/dump_<category>.cc`).
- `kind`: `i` (64-bit signed integers, decimal) or `f` (float32: any decimal
  that parses back to the same float32; the harness writes `%.9g` in the C
  locale, Swift its shortest round-tripping form). Equal dumps may differ in
  text, so dumps are compared parsed, never as text.
- `count`: number of values that follow; 0 is allowed.
- Name components are nonempty. Float values must be finite. A final LF is
  optional when parsing; writers always include it. Parsers accept fields in
  any order and reject duplicate names.
- Fields are sorted by name and appear once each. Separators are single spaces.

## Comparison rules

`SemanticDump.differences(from:)` implements these; an empty result means the
dumps agree.

1. Integer fields compare exactly, element by element.
2. Float fields compare within the tolerance this document lists for that
   field. A float field with no listed tolerance is a difference
   (`noTolerance`), never silently compared.
3. A field present in only one dump, a kind mismatch or a count mismatch is a
   difference.
4. Only the first differing element of a field is reported. Differences are
   sorted by field name. Structure is checked before float tolerances.
5. ULP distance uses monotonic float32 bit ordering, with signed zeros
   distinct and adjacent (0 ULP means bit-identical). Absolute tolerance is
   inclusive. Nonfinite values never compare equal.

A test that compares only some categories restricts both dumps first
(`restricted(to:)`).

## Expected divergence

A fixture for a decision Swift hasn't translated yet still runs. Expected
divergence is recorded per corpus entry **and category**
(`SemanticCorpusEntry.knownIssues`, category → set of issues): each (entry,
category) pair is its own test case, and only a listed pair runs under
`withKnownIssue("GER-338x …")`, naming every issue that must land before it
matches. The
other categories of the same entry are compared normally, so one untranslated
decision never hides another. A listed pair turns red the moment Swift starts
matching, which is the cue to remove it. Stage fixtures (`*.dump`) follow the
same rule per fixture (`StageFixtureKnownIssues`).

A fixture compared under a known issue verifies nothing: an inventory
`fixture` reference (`<path>#<category>` for a `.sem`) to it is a violation.
Never weaken a tolerance or drop a field to make a fixture pass.

## Adding a category (lanes B, C and D)

1. Add `Reference/harness/src/dump_<category>.cc`, which registers itself with
   `RegisterDumpCategory`; no shared source changes.
2. List its fields and any float tolerances below.
3. Add the Swift emitter for the same fields in
   `SemanticDump(swiftDecisions:)` and the category to
   `SemanticDump.swiftEmittedCategories`.
4. Regenerate the semantic fixtures (`Reference/make_semantic_fixtures.sh`) and
   their provenance rows.

A translation lane that changes `Encoder.encodeFrame`'s composition also
updates the test-side recomposition (`SwiftSemanticEncoding`) in the same
change: `recompositionMatchesEncoder` pins the two byte-identical and fails
until they agree.

## Categories

<!-- Each category lists its fields: name, kind, layout, and float tolerance. -->

| category | owner | fields |
|---|---|---|
| `frame` | lane A | to be filled when the category is built |
| `coeff_order` | lane A | to be filled when the category is built |
| `block_context` | lane A | to be filled when the category is built |
| `context_map` | lane A | to be filled when the category is built |
| `quant_field` | lane A | to be filled when the category is built |

## What the decoder does not retain

Without a libjxl patch (D-10), these are not recoverable from the decoder
state after a decode. A category that needs one re-parses the section with
libjxl's public decoder primitives, or the lane records it as out of reach:

- the ANS histogram precision (shift) choice: only the normalized counts survive,
  in the alias tables;
- quantized AC coefficients in a single-pass decode;
- quantized DC integers, and the modular DC tree, its histograms and context
  map (private to `ModularFrameDecoder`).
