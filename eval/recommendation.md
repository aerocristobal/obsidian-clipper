# Recommendation: merge B + C, defer A

**TL;DR**

Merge Spike B (JSON-LD fast path) and Spike C (SwiftSoup parser) into master as two separate, independent commits. Defer Spike A (Readability.js / JSC). Add a small follow-up scoring/post-processing fix for `fnn-fbi`'s recirc bleed-through. Total expected pass rate: **5/6** at meaningful but bounded cost.

## Why not Spike A alone, even though it's the highest-scoring single branch?

Spike A scores 5/6 (vs B+C's 4/6, vs B+C+follow-up's likely 5/6) and on raw extraction quality is the cleanest single drop-in. But the cost is real and concentrated in the share extension's tightest constraint: memory.

| Constraint | Cost |
|---|---|
| Share-extension memory cap | 120 MB (system-imposed, OOM kills) |
| Current extension idle | ~30 MB |
| JSC + readability bundle | **+25 MB resident** |
| HTMLToMarkdown working set on a large article | up to ~10 MB |
| Vision OCR (per image, 20 images max) | up to ~30 MB peak |
| Headroom remaining | **~25 MB**, before any contingency |

That's not impossible — Story 4.7's memory-pressure throttle exists for exactly this — but it eats most of the safety margin we have for the OCR path. And we'd be paying it for **every clip**, not just clips that benefit from Mozilla's algorithm. Most clips in the wild won't be Wired or FNN; they'll be Substack/blog content where the existing Swift port already works fine.

There are also softer arguments against shipping A right now:

- **Build pipeline.** The bundle is built with `npm run build` outside Xcode. Production needs that wired into a Run Script build phase or a pre-commit hook, with `npm install` reproducible in CI. Possible, but it's a meaningful operational addition for an iOS project that has no other Node dependencies.
- **JS update cadence.** We pin `@mozilla/readability ^0.5.0`. Mozilla syncs from Firefox Reader View; updates are infrequent but security-relevant when they happen, and we'd own re-running the eval corpus on each bump.
- **Cold-start latency.** First clip after install pays ~270 ms in the simulator. On real devices it's likely 100–200 ms. Tolerable for a one-shot share extension, but not free.

A is the best single approach if you're willing to spend the memory and adopt a Node toolchain in the iOS build. **It's an excellent escape hatch** — keep `spike/readability-jsc` alive as a documented option for when B+C stop being enough.

## Why B + C, in detail

**B and C address orthogonal failure modes**, which is the unusual property that makes their composition nearly free.

- **B** improves the cases where the publisher already embedded the article body (Wired, plausibly NYT/Reuters/AP/major Substacks, ~?% coverage on a wider corpus). When it fires, the result is the publisher-of-record body — there is no scoring gamble. When it doesn't fire, fall-through is byte-identical to master.
- **C** improves the cases where the byte-level HTML parser truncated or fragmented the tree. The `fnn-ex-feds` flip from 948 chars to 10961 chars is the canonical case — same scoring, just on a tree that wasn't broken. Zero behavioral regressions on the existing 86-test suite.

These don't compete. B sits *in front* of the pipeline; C sits *underneath* the pipeline.

### Cost accounting for B + C

| Cost | Amount |
|---|---|
| Memory (runtime) | trivial |
| Binary size (universal) | +5–6 MB (SwiftSoup) |
| Binary size (after App Store thinning, on-device) | ~+2.5–3 MB |
| Code | ~315 LOC across 3 new files |
| Build pipeline | none (SPM auto-resolves) |
| New deps | SwiftSoup 2.13.4 |

The +5–6 MB binary is the single non-trivial cost. App Store thinning halves it on-device. SwiftSoup's source is pure Swift, well-maintained, low-frequency updates.

### Expected results after B + C land

| Fixture | Result | Source |
|---|---|---|
| electrek-bluetti | ✗ | Neither B nor C addresses the "Subscribe to Electrek" recirc bleed-through. Needs a small targeted scoring/post-processing fix. |
| fnn-ai-productivity | ✓ | Already passing. |
| fnn-ex-feds | ✓ | C's tree recovery. |
| fnn-fbi | partial → ✓ with follow-up | C extracts the body; a small recirc paragraph still bleeds. 20-LOC post-processing fix. |
| wired-anthropic | ✓ | B's fast path. |
| wired-michael | ✓ | B's fast path. |

**Expected: 4/6 immediately after B+C, 5/6 after the small follow-up.** Comparable to A's 5/6 (after fixture-canary fix).

## Recommended merge order

1. **First:** Merge `spike/jsonld-fastpath` → `main`. Lowest risk, highest fall-through guarantee, immediately fixes Wired clips.
2. **Second:** Merge `spike/swiftsoup` → `main`. Modest-risk SPM addition; gives parser quality across the board.
3. **Follow-up commit on main:** Address the `fnn-fbi` recirc bleed and the `electrek-bluetti` "Subscribe" must-not-contain. Both look like targeted post-processing strips of subtrees with `class*="related"`, `class*="trending"`, `class*="recirc"`, or content that begins with phrases like "Subscribe to". Should be ~30 LOC of targeted post-processing in `ReadabilityExtractor.postProcess`.
4. **Re-run the eval harness** after each step. Confirm no regression vs master, and confirm the expected fixture flips.

## What stays alive on the shelf

- `spike/readability-jsc` — keep the branch. If B+C+follow-up doesn't hold up on a wider corpus (NYT, Substack, niche tech blogs, malformed older HTML), this is the next lever. Memory cost is real but bounded; the Mozilla algorithm covers cases neither B nor C can.
- `spike/eval-harness` — keep the branch as the basis for any future spike. The corpus and harness should be expanded over time (target: 30 fixtures across publisher categories) so future architecture decisions have data.

## Wired Michael's missing-source-URL bug

Out of scope for this comparison, but worth tracking: when the user re-clipped `wired-michael`, the produced markdown had no `source:` line in its frontmatter. That means `rawContent.url` was `nil` from `WebContentExtractor`, which is a Safari/Action.js path issue (the share-sheet input didn't carry a URL). All four extraction approaches handle the HTML correctly when given it directly; the issue is upstream of extraction. File a separate ticket against `WebContentExtractor` / `Action.js`.

## Action items

- [ ] Cherry-pick or merge `spike/jsonld-fastpath` → `main`
- [ ] Cherry-pick or merge `spike/swiftsoup` → `main`
- [ ] Run eval harness on `main` after each merge; confirm 4/6 then plan the small follow-up
- [ ] Write the follow-up: post-processing strip for related/trending/recirc subtrees + "Subscribe to" prefixed paragraphs
- [ ] Build + install on device, re-clip the four originally-reported URLs to confirm the user-visible behavior
- [ ] Expand the corpus (target 30 fixtures); re-run all four approaches; revisit A if B+C+follow-up doesn't generalize
