# Pixel model fixture provenance

The bounded pixel model observations were produced from libjxl commit `a7a9c787341cf703dede03c2009fa460cae5e5df`. The source probe calls `FindBestBlockEntropyModel` with real `ImageI` and all-DCT8 `AcStrategyImage` inputs. `Reference/pixel-model-producer-commands.json` records the normalized compile commands; `Reference/provenance.tsv` records each fixture's SHA-256 and input configuration.

The selected build used Xcode 27.2 Apple clang 21.0.0, arm64, C++17, Release `-O3 -DNDEBUG`, and the configured NEON baseline. The selected `enc_heuristics.cc.o` SHA-256 is `21abe78e755632293770db2d2e14cfb6fafb0eb3c6a3efc19aa75079a1b34838`. The initially configured harness SHA-256 is `1440ea0f68492616b742ce33cb6caf067c7bd087d0dfe0ab91813665cdc0d3ef`; the fixture producer command and source remain recorded separately.

These files preserve bounded source observations and producer provenance. Tests use them to verify unchanged source fields and classify map differences; source sorting output is not a Swift pass criterion. The native Swift model tests pin the selected language-boundary behavior independently.
