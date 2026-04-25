# Spike A — Readability.js + linkedom in JavaScriptCore

**Branch:** `spike/readability-jsc`
**Recommendation:** **merge-with-changes** (build-script automation + 1 fixture deck-paragraph fix).

## TL;DR results

| | master (Swift port) | readability-jsc |
|---|---|---|
| Fixtures passing | 2/6 | **5/6** |
| Cold init | 0ms | ~270ms (one-time) |
| Per-fixture warm | 50–500ms | 18–660ms |
| Bundle size on disk | n/a | 538KB (JS) |
| Resident memory delta | 0 | ~25MB after JSContext + bundle eval |

## What was implemented

1. **JS bundle** (`ClipperExtension/Resources/readability-bundle/`)
   - `entry.js` exports `extractArticle(html, url)` that runs `linkedom.parseHTML` → `Readability.parse()` and returns a JSON string with `{title, content, excerpt, siteName, byline, length}`. On error, returns a `{__error}` envelope so Swift can log without scraping JSValues.
   - Built with `esbuild --bundle --format=iife --global-name=ReadabilityKit --target=es2017`. Output: `ClipperExtension/Resources/readability-bundle.js` (538KB).
   - Injects a `<base href>` tag into the parsed document so Readability resolves relative `<img>`/`<a>` URLs against the page URL.
   - Tree-shakes off the heavy `canvas` native binding (linkedom guards it with try/catch + shim — verified in bundle output around line 1591).

2. **Swift adapter** (`ClipperExtension/JSCReadabilityExtractor.swift`)
   - Single shared `JSContext` initialized lazily and serialized through a private `DispatchQueue` (JSC is not thread-safe).
   - **Polyfills installed before bundle eval:** `console.log/.warn/.error` (NSLog in DEBUG only), `atob`, `btoa`. The `atob` polyfill is **load-bearing** — without it the bundle throws `ReferenceError: Can't find variable: Buffer` because `htmlparser2`'s entity decoder probes `typeof atob === "function"` first, and a bare JSContext has neither `atob` nor `Buffer` in scope.
   - Resource lookup tries `Bundle(for: BundleAnchor.self)` first (works for both the share extension and the xctest bundle), then `Bundle.main`, then `Bundle.allBundles`.
   - Resident memory measured via `mach_task_basic_info` before and after first JSContext init. Logged once per process.

3. **Eval harness wiring** (`ObsidianClipperTests/EvalEntryPoint.swift`)
   - `approachName = "readability-jsc"`.
   - Pipeline: `replaceImgTagsWithMarkers` → `JSCReadabilityExtractor.extract` → `HTMLToMarkdown.convert(_: String)` (the string overload — passes Readability's article HTML directly to the existing converter).
   - Falls back to the master `ReadabilityExtractor` then full-HTML conversion if JSC is unavailable or returns null/short content. Mirrors the live `ShareViewController` <100-char threshold.

4. **Xcode project** (`ObsidianClipper.xcodeproj/project.pbxproj`)
   - Added `JSCReadabilityExtractor.swift` to the ClipperExtension Sources (and to the test target Sources, mirroring how the other shared extension files are dual-compiled).
   - Added `readability-bundle.js` as a resource on both the ClipperExtension target *and* a new `Resources` build phase on the ObsidianClipperTests target — `@testable import ClipperExtension` doesn't transfer the resource, so the test bundle needs its own copy for `Bundle(for:)` lookup to work.

## Bundle size & memory

- **On-disk bundle:** 538KB (target was <500KB; linkedom is ~70% of this).
- **Cold init cost:** ~270ms total — JSContext create + bundle parse/eval. Logged once.
  ```
  [JSCReadability] cold init: bundle=273.0ms residentΔ=25.1MB before=175620096 after=201932800
  ```
- **Resident memory delta after init: ~25MB.** That's a real chunk in a 120MB share-extension budget, but it's bounded — JS heap usage doesn't grow dramatically between calls (LinkedDOM and Readability throw away their per-call allocations on the next `extractArticle` call). The big consumer is the JSContext + Readability's pre-compiled regex tables.
- **Per-call cost:** First call after cold init bears the 270ms; subsequent calls are 18–660ms wall-clock dominated by HTML parse time (proportional to document size).

## Per-fixture results

| Fixture | master | jsc | Δ body chars (jsc-master) | Notes |
|---|---|---|---|---|
| electrek-bluetti | ✗ | ✓ | -781 | jsc cleanly drops `[Subscribe to RSS]` boilerplate that triggered master's must-not-contain. Image markers preserved (7/7). |
| fnn-ai-productivity | ✓ | ✓ | +12 | Both pass. |
| fnn-ex-feds | ✗ | ✗ | +7153 | jsc extracts a much larger article (8101 vs 948) — master was failing because it grabbed the wrong subtree. **The ✗ now is a fixture problem**: must-contain looks for the deck paragraph "Many former federal employees are navigating the job market…" which Readability.js drops as part of its lead-in cleanup. The actual interview transcript is fully intact. Recommended fix: change the must-contain to a phrase from the body. |
| fnn-fbi | ✗ | ✓ | +3124 | Master only got 764 chars (failed min_body_chars). jsc extracts the full report. |
| wired-anthropic | ✗ | ✓ | +1885 | Master's chunked-body bug (note in `ReadabilityExtractor.scoreCandidates` comment) doesn't apply here — Readability.js handles the chunking natively. |
| wired-michael | ✓ | ✓ | -3746 | Both pass. jsc is more aggressive about stripping recirc widgets, which actually improves the must-not-contain score. |

## Surprises

1. **`atob` is not on JSContext by default.** I assumed it was because it's a Web API and JavaScriptCore originated as Safari's engine. It is *not* — `atob`/`btoa` are added to the global scope only when JSC is wired up to a DOM environment (WKWebView). Bare `JSContext` is closer to ES2018 + a few extras. Without the polyfill, `htmlparser2`'s entity decoder takes the `Buffer.from` path, throws `ReferenceError`, and Readability never even gets the chance to run.
2. **`[[IMG:N]]` markers DO survive Readability.js.** I had flagged this as an integration risk in the spike spec. In practice, markers placed inside `<p>` text content by `replaceImgTagsWithMarkers` get carried through Readability's serialization unchanged. `electrek-bluetti` has 7/7 markers preserved — same count as master. Risk downgraded.
3. **Bundle size came in at 538KB**, slightly above the 500KB target. Most of that is `linkedom`'s entity tables and the htmlparser2 state machine. Could be trimmed with `--minify` (~30% reduction) — left disabled for spike legibility.
4. **Cold-init was 270ms in the simulator, vs. the ~80ms estimate.** Not awful, but worth measuring on-device before shipping. The dominant phase is bundle parse, not JSContext create.

## Known shortcomings

- **No esbuild minification.** Trivial to enable; left off so the bundle is readable when debugging.
- **No CI build step for the bundle.** A maintainer who edits `entry.js` has to remember to re-run `npm run build`. Should be wired into a Run Script build phase or a pre-commit hook before merging to master.
- **No JSC error recovery beyond null-return.** If the bundle gets into a bad state (e.g. an OOM kills the JS heap mid-call), the shared context stays poisoned. A production version should detect that and rebuild the context. Not exercised by the corpus.
- **Linkedom tree-shake is incomplete.** The bundle includes a `canvas` shim path even though it's never executed. Saving 10–20KB is possible with explicit aliasing in esbuild config.

## Integration risks (production share extension)

1. **Memory headroom.** Share Extensions get ~120MB. ~25MB for the JSContext + bundle is a meaningful chunk, especially overlapped with HTML parsing on the Swift side and Vision OCR on a separate path. Mitigations: tear the JSContext down between clips (cheap on amortized terms — re-init is 270ms once), or skip the Swift HTML parse entirely (HTMLToMarkdown.convert string overload re-parses what Readability already serialized).
2. **JSC cold-start latency.** First clip after install pays the 270ms. Acceptable for a one-shot share extension where total user-visible latency is already 1–3s. Not acceptable if the extension is shown on a hot path.
3. **App Review.** JavaScriptCore is a system framework, no special entitlement needed. Bundling minified third-party JS shouldn't trigger any review flags — it's no different from bundling a CSS file. Note that this is **not** dynamic code execution in the App Review sense (no remote fetch).
4. **Readability.js maintenance.** We pin `@mozilla/readability ^0.5.0`. Updates are infrequent (Mozilla syncs from Firefox Reader View) and we should rebuild + re-run the eval corpus on every bump.
5. **Image positioning.** Verified marker preservation on the corpus (7/7 on electrek-bluetti). Should add a marker-survival assertion to the eval criteria before shipping.

## How to rebuild the bundle

```bash
cd ClipperExtension/Resources/readability-bundle
npm install   # one-time
npm run build # writes ../readability-bundle.js
```

## Verification commands run

```bash
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' \
  -only-testing:ObsidianClipperTests/ExtractionEvalTests test
```

Output: `eval/readability-jsc/summary.json` shows 5/6 fixtures all_passed, with the 1 failure being a fixture-criteria mismatch rather than an extraction defect.

## One-line recommendation

**Merge-with-changes** — wire bundle build into Xcode, fix the one fixture's must-contain (or accept the deck-paragraph drop), and document the ~25MB JSContext footprint in the share-extension architecture notes.
