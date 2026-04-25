# Extraction approach comparison: master vs A vs B vs C

**Corpus:** 6 real-world articles (4 originally-reported + 2 regressions)
**Harness:** `ObsidianClipperTests/ExtractionEvalTests.swift` — identical scoring across branches
**Date:** 2026-04-25

## Pass/fail matrix

| Fixture | Master | A: Readability.js + JSC | B: JSON-LD fast path | C: SwiftSoup parser |
|---|:-:|:-:|:-:|:-:|
| electrek-bluetti | ✗ | **✓** | ✗ (fall-through) | ✗ |
| fnn-ai-productivity | ✓ | ✓ | ✓ (fall-through) | ✓ |
| fnn-ex-feds | ✗ | ✗* | ✗ (fall-through) | **✓** |
| fnn-fbi | ✗ | **✓** | ✗ (fall-through) | partial† |
| wired-anthropic | ✗ | **✓** | **✓** (JSON-LD fired) | ✗ |
| wired-michael | ✓ | ✓ | ✓ (JSON-LD fired) | ✓ |
| **Pass count** | **2/6** | **5/6** | **3/6** | **3/6** |

\* A's `fnn-ex-feds` ✗ is a fixture-criteria mismatch, not an extraction defect: Readability.js drops the deck paragraph our `must_contain` canary lived in, but the full 8101-char interview transcript is intact (vs master's 948 chars). With a different canary phrase, A would be 6/6.

† C's `fnn-fbi` extracts the body successfully (must_contain 2/2, body 5165c vs master's 764c) but a recirc paragraph still bleeds through (must_not_contain 2/3). Improvement from "no body at all" to "body + small recirc bleed" — fixable with a small targeted scoring/post-processing tweak.

## Body-character delta (vs master)

| Fixture | Master | A | B | C |
|---|---|---|---|---|
| electrek-bluetti | 5662 | 4881 | 5662 | 5662 |
| fnn-ai-productivity | 6954 | 6966 | 6954 | 9000 |
| fnn-ex-feds | 948 | **8101** | 948 | **10961** |
| fnn-fbi | **764** | **3888** | 764 | **5165** |
| wired-anthropic | 2918 | 4803 | 4223 | 2918 |
| wired-michael | 9273 | 5527 | 4103 | 9273 |

Bold = substantial body-volume change. A and C both rescue FNN articles where master truncated to <1000 chars.

## Per-fixture timing (ms)

| Fixture | Master | A | B | C |
|---|---|---|---|---|
| electrek-bluetti | 103 | 660 | 164 | 241 |
| fnn-ai-productivity | 90 | 177 | 313 | 244 |
| fnn-ex-feds | 74 | **24** | 72 | 226 |
| fnn-fbi | 53 | **18** | 61 | 150 |
| wired-anthropic | 428 | 74 | **10** | 311 |
| wired-michael | 475 | 85 | **15** | 356 |

A's per-fixture warm time is consistently fast once initialized; B's fast-path hits are 30–40× faster than master's full Readability run; C is uniformly slower (SwiftSoup tree-builder cost) but never pathologically so.

## Cost summary

| Approach | Memory | Binary | Code | Build pipeline | New deps | Risk |
|---|---|---|---|---|---|---|
| **A: Readability.js / JSC** | **+25 MB** resident (cold init ~270ms one-time) | +538 KB JS bundle | +500 LOC Swift+JS | npm + esbuild build step | `@mozilla/readability`, `linkedom` (vendored as bundle) | JSC lifecycle, JS update cadence, share-extension memory cap |
| **B: JSON-LD fast path** | trivial | trivial | +210 LOC Swift | none | none | minimal |
| **C: SwiftSoup parser** | trivial | **+5–6 MB** universal (~+2.5 MB arm64 `__TEXT`) | +105 LOC Swift | SPM resolution | SwiftSoup 2.13.4 | new SPM dep, bigger appex |

## Where each approach helps

- **Master fails the cleanest on:** Wired's chunked `BodyWrapper` layout (recirc wins) and FNN's `Entry-content` getting truncated by the byte parser.
- **A wins on:** every fixture except `fnn-ex-feds` (and that's a canary problem, not a body problem). Mozilla's polished algorithm is the most consistently good.
- **B wins on:** publishers that emit `Article.articleBody` in JSON-LD. In our corpus that's exactly Wired (2/6). Free fall-through everywhere else — byte-identical to master output, no risk to non-Wired fixtures.
- **C wins on:** parser-quality cases. FNN's `fnn-ex-feds` was a parser truncation (master got 948 chars, SwiftSoup got 10961). Also extracts more on `fnn-fbi` and `fnn-ai-productivity` though the latter was already passing.

## Composition possibilities

| Composition | Estimated pass | Cost | Notes |
|---|:-:|---|---|
| B alone | 3/6 | trivial | covers Wired, no other change |
| C alone | 3/6 | +5–6 MB binary | covers FNN tree-builder cases |
| **B + C** | **4/6** | **+5–6 MB** | catches Wired (B fast path) AND FNN ex-feds (C parser); fnn-fbi still partial |
| B + C + targeted recirc strip on fnn-fbi | likely 5/6 | +5–6 MB + 20 LOC | the recirc bleed on fnn-fbi is fixable in post-processing |
| A alone | 5/6 | +25 MB + 538 KB + npm | maximum coverage, highest cost |
| A + B (B fast path, A fallback) | 5/6 | A's cost + B's | B handles Wired without invoking JSC; A handles the rest |

## Image preservation

Image marker counts (`[[IMG:N]]` surviving extraction — proxy for "what would actually be downloaded"):

| Fixture | Master | A | B | C |
|---|---|---|---|---|
| electrek-bluetti | 7 | 7 | 7 | 7 |
| all others | 0 | 0 | 0 | 0 |

`electrek-bluetti` is the only image-rich fixture in the corpus. All four approaches preserve all 7 markers. Image filtering downstream (already shipped in master) handles the chrome-image problem orthogonally.

## Notable surprises

- **JSContext doesn't expose `atob`/`btoa`** — A's bundle requires a Swift-side polyfill before Readability can run. Without it, htmlparser2's entity decoder takes the `Buffer.from` path and ReferenceErrors out.
- **`[[IMG:N]]` markers DO survive Readability.js.** Originally flagged as a risk for branch A; verified intact on the only image-rich fixture.
- **Only Wired exposes `articleBody` in our corpus.** All 6 fixtures embed JSON-LD `NewsArticle` blocks, but only Wired populates the body field. FNN omits it; Electrek omits it. Coverage of B is publisher-dependent.
- **C's SPM integration was clean on first try.** The Xcode project lacked existing SPM packages, but SwiftSoup resolved on a single `xcodebuild -resolvePackageDependencies` invocation. No vendoring fallback needed.
- **C's parser strictly improves body recovery without a single regression** in the existing 86-test suite. The HTMLNode adapter held its contract.

## Reproducibility

Each branch's eval output:
- `eval/master/{summary.json, *.md}` — control
- `eval/readability-jsc/{summary.json, *.md, notes.md}` — branch A
- `eval/jsonld-fastpath/{summary.json, *.md, notes.md}` — branch B
- `eval/swiftsoup/{summary.json, *.md, notes.md}` — branch C

To re-run any branch:
```bash
cd <worktree-path>
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' \
  -only-testing:ObsidianClipperTests/ExtractionEvalTests test
```

To compare:
```bash
diff <(jq .fixtures eval/master/summary.json) <(jq .fixtures eval/<branch>/summary.json)
```
