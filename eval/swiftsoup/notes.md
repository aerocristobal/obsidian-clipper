# Spike C — SwiftSoup parser swap

## Summary

Replaced the byte-level `HTMLParser` in `ReadabilityExtractor.swift` with
SwiftSoup (jsoup port) via an adapter that emits the existing `HTMLNode`
tree. All scoring, post-processing, and Markdown conversion paths are
unchanged — the win, if any, is HTML5-conformant parsing on malformed
real-world input.

## Integration choice: Option A (SPM) — succeeded

Edited `ObsidianClipper.xcodeproj/project.pbxproj` directly to add:
- `XCRemoteSwiftPackageReference` for `https://github.com/scinfu/SwiftSoup.git` (`upToNextMajor` from `2.7.0`, resolved to **2.13.4**)
- One `XCSwiftPackageProductDependency` per consuming target (`ClipperExtension`, `ObsidianClipperTests`)
- A `PBXFrameworksBuildPhase` for each consuming target linking the `SwiftSoup` product
- `packageReferences` on the `PBXProject` object
- `packageProductDependencies` on each consuming target
- A new `ClipperExtension/SwiftSoupAdapter.swift` source file (added to both target Sources phases via the existing dual-membership pattern used for the rest of the extension code)

`xcodebuild -resolvePackageDependencies` succeeded on the first attempt.
No need for the Option B vendoring fallback.

The SPM friction was minimal because the project already had the
"compile every ClipperExtension source into the test target" duplication
pattern (e.g. `A10000080`–`A10000086` mirror `A10000021`–`A10000028`),
so wiring `SwiftSoupAdapter.swift` into both targets required just two
new `PBXBuildFile` rows plus the file reference. All UUIDs use the
project's `A1xxxxxx`/`A2xxxxxx`/`A91111xxx` namespacing so they don't
collide with anything Xcode might generate.

## Test pass-rate

All 86 existing tests pass — **no behavioral regressions** introduced
by the parser swap.

```
HTMLToMarkdownTests:        58/58 passed
ReadabilityExtractorTests:  28/28 passed
```

This includes the byte-parser-specific edge cases:
- `testJapaneseTextNodePreservesUTF8` — SwiftSoup decodes UTF-8 cleanly
- `testCJKParsePerformanceBaseline` — 95 ms average for ~200 KB CJK
  HTML (vs the byte parser's previous baseline; not directly comparable
  on this hardware, but well within the test's lax bounds)
- `testMalformedHTMLDoesNotCrash`
- `testHTMLEntityDecoding`
- `testReadmoreClassIsNotPenalizedForAdSubstring` — the `<aside>` is
  preprocessed away before scoring, so this still holds
- `testRoundUpPostWithLinkedHeadingsStillExtracts` — heading-damping
  floor still kicks in correctly with SwiftSoup's tree

The `HTMLNode` adapter contract held: tag names lowercased, attribute
names lowercased, text nodes carry raw decoded text, parent pointers
wired up, comments/doctypes dropped. No downstream code change was
needed.

## Eval pass-rate (corpus: 6 fixtures)

| Fixture | Master | SwiftSoup | Δ |
|---|---|---|---|
| electrek-bluetti | ✗ (mnc 0/1) | ✗ (mnc 0/1) | same |
| fnn-ai-productivity | ✓ | ✓ | same |
| fnn-ex-feds | ✗ (mc 0/1) | **✓** (mc 1/1, mnc 3/3) | **+win** |
| fnn-fbi | ✗ (mc 0/2, body 764c) | ✗ (mc 2/2, mnc 2/3, body 5165c) | **partial-win** |
| wired-anthropic | ✗ (mc 0/1) | ✗ (mc 0/1) | same |
| wired-michael | ✓ | ✓ | same |

**Net: 3/6 pass vs master's 2/6** (+1 fixture full-pass, +1 fixture
substantial improvement).

### Where SwiftSoup parsing made a measurable difference

- **`fnn-ex-feds`** (Federal News Network, "ex-feds" article): was
  failing on master with `mc=0/1` and only 948 body chars — the byte
  parser was getting a small fragment of the article. SwiftSoup
  produces a 10,961-char body that contains every `must_contain`
  needle and is clean of every `must_not_contain` needle. Likely
  cause: FNN injects WordPress comment markers and inconsistent tag
  closures in the body, which the byte parser truncated where
  SwiftSoup's HTML5 tree-builder recovered.

- **`fnn-fbi`** (FNN, FBI Signal-targeting article): was the worst
  master result (`mc=0/2`, 764 chars, body-too-short). SwiftSoup
  brings it to 5,165 chars with both must-contains hitting and 2/3
  must-not-contains clean. Still fails one must-not-contain check —
  some sidebar text leaks through — but this is an ordering/scoring
  issue, not a parsing issue. The byte parser was losing the body
  outright.

### Where SwiftSoup did NOT help

- **`electrek-bluetti`**: identical body chars and same must-not-
  contain failure as master. The fixture's failure mode is content
  bleed-through unrelated to parser correctness.

- **`wired-anthropic`**: identical (2918 chars, mc 0/1). Wired uses
  fragmented `BodyWrapper` chunks (the same pattern the
  `linkedHeadingDamping` code addresses); the recirc widget is still
  beating the article body. This is a scoring problem, not a parse
  problem.

### Wall-clock cost

SwiftSoup parsing is roughly **2-3× slower than the byte parser** on
these fixtures (e.g. wired-anthropic 311 ms vs master 428 ms — actually
faster! — but most fixtures show a 100-200 ms increase). On a real
share extension ~50-300 KB HTML budget this stays well under the iOS
60-second extension timeout, but it's worth noting.

## Binary size delta

Static-link Release build (iOS Simulator, x86_64 + arm64 universal):

- **`ClipperExtension.appex` total binary**: 9,883,984 bytes (9.42 MB)
- **arm64 `__TEXT` segment**: 2.87 MB (this is the code that ships)
- **SwiftSoup-mangled symbols linked into the appex**: 8,643
- **SwiftSoup.o (intermediate static archive, Release)**: 12.5 MB
  (linker dead-strips ~80% of it)

I was prevented (sandbox boundary) from building the master baseline
in a separate DerivedData location, so I cannot give a clean
diff-against-master in bytes. From the symbol counts and the original
ClipperExtension code volume (~700 LOC of byte parser plus a few small
files), the master appex `__TEXT` would be on the order of 200-400 KB.

**Estimated delta: +2.5 MB to +2.7 MB to the arm64 `__TEXT` segment,
or +5 MB to +6 MB to the universal-binary on-disk size.** This **exceeds
the +2 MB target** stated in the success criteria.

For a share extension constrained to ~120 MB runtime memory, the
binary-size hit is a real concern: the Swift runtime + loaded code
maps in mostly at startup, and SwiftSoup's byte-buffer + Tag/Element/
Attributes class graph is not lazy. A real ship would want to:
1. Verify the *device* arm64 binary (not simulator universal) — the
   Mac slice usually dwarfs arm64.
2. Profile share-extension startup memory under typical pages.

## Integration risk

- **Memory budget**: SwiftSoup builds a full DOM (one `Element` class
  instance per tag, one `Attributes` collection per element, one
  `Attribute` per attribute). The byte parser produces a leaner tree
  structurally identical to what we hand off after adapter conversion.
  On large pages SwiftSoup's intermediate DOM peaks before we throw
  it away in `convert(node:)`. Worth stress-testing.
- **Thread safety**: SwiftSoup's `Document` is not documented as
  thread-safe. We parse synchronously inside `extract`, so this isn't
  a concern for the current pipeline, but anyone tempted to share
  parsed documents across actors would need to verify.
- **Maintenance**: SwiftSoup is actively maintained (2.13.4 is recent),
  pure Swift, MIT-licensed. Low maintenance risk.
- **Library versioning**: pinned to `upToNextMajor` from 2.7.0 — minor
  releases auto-pulled, breaking changes blocked.

## Recommendation

**merge-with-changes.** SwiftSoup is a clear correctness win on the
fragmented-body cases (FNN articles) and zero regressions on the
existing test corpus. But the **+5–6 MB universal-binary cost** is
larger than the spike target permits. Two paths forward:

1. **Accept the size cost** if extraction quality on real-world feeds
   matters more than IPA size. App Store thinning will halve the
   delta on user devices (single-arch download).
2. **Vendor only the parsing subset of SwiftSoup** (the Tokeniser,
   TreeBuilder, and minimum DOM types) — drops CSS selectors, the
   pretty-printer, and the cleaner. Could plausibly cut 50% off the
   linked code size.

Either way, the parser swap itself is sound — Stream A's scoring code
is robust enough that swapping the parser cost zero behavioral
regressions.
