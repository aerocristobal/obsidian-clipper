# Obsidian Clipper — Repo Assessment & Capability Roadmap

**Date:** 2026-06-12
**Scope:** Review of `main` against the PRD problem statement and goals; capture-pattern evaluation for anti-clipping sites (wired.com, nytimes.com class); hardening, performance, and resource recommendations; resulting epic backlog (tracked as motes — see § 6).

---

## 1. PRD goal scorecard

> PRD problem statement: *"A user reading an article behind a login wall on their phone should be able to tap Share → Clip to Obsidian and end up with a clean, linked, searchable Markdown note in their vault — within seconds, with no network hop to a third-party service."*

| PRD goal | Status | Evidence |
|---|---|---|
| G1 One-tap capture from anywhere | ⚠️ Partial | Extension activates everywhere, but URL-only shares (Messages, X, Reddit) re-fetch unauthenticated and fail silently on paywalls/bot-blocks/SPAs. |
| G2 Clean Markdown output | ✅ Strong, known gaps | Tree-based converter + SwiftSoup Readability. Recirc bleed-through on 2/11 corpus fixtures (`electrek-bluetti`, `fnn-fbi`); ~30 LOC postProcess fix already designed. |
| G3 Preserve authenticated content | ✅ Safari path / ❌ re-fetch path | `Action.js` captures the live authenticated DOM from Safari — the headline scenario works. The re-fetch path cannot (no cookies) and **never tells the user it lost**. |
| G4 Self-contained clips | ✅ | Per-article subfolders, inline `[[IMG:N]]` markers, image dedup, orphan appendix. |
| G5 Privacy by construction | ✅ | On-device only; only origin fetches. The (planned, opt-in) archive fallback is the sole deliberate exception — see E7. |
| G6 Survive ~120 MB memory cap | ✅ Strong | Streamed image downloads, 50 MB cumulative cap, 20-image cap, Vision downscale, memory-warning throttle, scoped HTML strings. |

**Bottom line:** the Safari share path delivers the PRD promise. The product's biggest gap is the *non-Safari* share path: it fails silently and dishonestly on exactly the sites the PRD names (paywalled, dynamic, authenticated).

## 2. Capture-pattern evaluation: wired.com, nytimes.com, and hostile sites

How the two share paths behave today:

| Scenario | From Safari (Action.js) | From other app (re-fetch) |
|---|---|---|
| Paywalled, user logged in (NYT, Wired) | ✅ Live authenticated DOM captured | ❌ Paywall stub or login page; saved without warning |
| Bot-block / Cloudflare 403, 429 | ✅ (already rendered) | ❌ Was silent `nil` → generic "no content" *(now: typed error, see § 4)* |
| JS-rendered SPA | ✅ (DOM already rendered) | ❌ Empty shell; Readability scores empty divs |
| Slow/flaky network | n/a | ❌ Was single attempt, 15 s timeout, silent failure *(now: 2 retries + backoff)* |

Wired-specific note: the JSON-LD fast path (`JSONLDExtractor`) already makes Safari-shared Wired articles the best case in the corpus (publisher-declared `articleBody`, 10–13 ms vs 428–475 ms for Readability). NYT-class publishers emit the same Schema.org markup **including `isAccessibleForFree: false`** — which the codebase does not yet read. That flag is the keystone of the paywall-detection epic (E4).

### 2.1 The layered fallback ladder (adopted strategy)

```
Tier 0  Plumbing: retry w/ jittered backoff (2 retries; timeout/5xx/429),
        errors surfaced to UI (never silent nil), cancellation-safe   [SHIPPED]
Tier 1  Direct fetch (mobile Safari UA) → run PaywallDetector on result   [E4]
Tier 2  If stub: desktop-Safari-UA re-attempt, then link[rel=amphtml]
        fetch (same origin, privacy-pure)                                 [E5]
Tier 3  If still stub AND "JS-rendered, not paywalled": WKWebView render,
        8s hard cap                                                       [E6]
Tier 4  If paywall detected: honesty card — "log in via Safari and share
        from there" + Copy URL + "Save partial anyway"
        (frontmatter: clip_quality: partial)                              [E4]
Tier 5  Opt-in only: archive.org availability lookup
        (sends URL, never content)                                        [E7]
```

**Guiding principle: the Safari path IS the paywall solution; the re-fetch path's job is to escalate intelligently and be honest when it loses.**

PaywallDetector signals, in confidence order: JSON-LD `isAccessibleForFree: false` → JSON-LD `wordCount`/`articleBody` length vs extracted-body ratio → paywall CSS classes (`paywall|regwall|meter|piano|tp-modal`) → "Subscribe to continue"-style terminal paragraphs → body floor (<600 chars when `og:type=article`).

WKWebView note (Tier 3): usable in share extensions; the page's JS heap lives in the separate `com.apple.WebKit.WebContent` process, so extension-side cost is ~15–30 MB of hosting overhead. Its `WKWebsiteDataStore` is the app's own — **it never sees Safari's cookies**, so this tier solves SPAs and never paywalls. Gated behind a timeboxed on-device memory spike (go/no-go).

### 2.2 Explicitly rejected techniques

- **Googlebot / crawler UA spoofing.** Major paywalled publishers verify crawlers by reverse-DNS/IP range, so it mostly fails where it would matter; where it works, it works by impersonating infrastructure to defeat access controls — contradicting the PRD's "user-initiated fetcher" framing and creating App Store / publisher-relations exposure. A **desktop Safari UA** second attempt is the line we draw: a real user-agent class, not impersonation.
- **Cookie mirroring from an in-app login** (App Group cookie store). Users would maintain a second login per site; sessions rot; storing auth cookies in a shared container is a real liability for an app whose brand is privacy. Share-from-Safari already delivers the same outcome with zero maintenance. Revisit only with evidence that non-Safari paywall shares dominate usage.

## 3. Hardening, performance & resource findings

| # | Finding | Location | Severity | Status |
|---|---|---|---|---|
| 1 | Stale-bookmark refresh was fire-and-forget `Task.detached` that did not hold the security scope — could silently fail; vault access rots | `FileSaver.swift` | **Critical** | **Fixed 2026-06-12** (synchronous refresh in-scope via `ClipperSettings.persistVaultBookmark`) |
| 2 | Vision OCR had no timeout — a hung request hung the clip (and blocked the actor, since `handler.perform` is synchronous) | `ImageProcessor.swift` | High | **Fixed 2026-06-12** (off-actor OCR raced against 30 s timeout, exactly-once resume) |
| 3 | URL re-fetch was single-shot `try?` with silent `nil` on 403/timeout | `WebContentExtractor.swift` | High | **Fixed 2026-06-12** (2 retries, jittered backoff on timeout/5xx/429; typed `FetchError`; `ClipError.fetchFailed` names the cause and hints the Safari path) |
| 4 | `<img>`/`<source>` tag regexes recompiled per call; `<source>` failure path was silent | `HTMLToMarkdown.swift` | Medium | **Fixed 2026-06-12** (precompiled statics, logged failure paths) |
| 5 | Double HTML parse on the Readability path (marker-injection byte parse + SwiftSoup parse), ~200 ms on large articles | `ClippingPipeline.swift` / `HTMLToMarkdown.swift` | Medium | Backlog → E3 |
| 6 | No `NSFileCoordinator` around vault writes (iCloud sync daemon race) | `FileSaver.swift` | Medium | Backlog → E1 |
| 7 | Downloaded images not validated against `Content-Length`; truncated files can land in the vault | `ImageProcessor.swift` | Medium | Backlog → E1 |
| 8 | No Retry button on error state; user must cancel and re-share | `ShareViewController/ShareExtensionView` | Medium | Backlog → E4 |
| 9 | No stale-bookmark warning in Settings (green check shown even when stale) | `SettingsView.swift` | Low | Backlog → E1 |
| 10 | OCR memory throttle gates only newly seeded tasks; in-flight `.accurate` requests (2–5 MB each) finish ungated | `ImageProcessor.swift` | Low (by design) | Documented; revisit if OOM reports appear |
| 11 | Recirc/related-content bleed-through on 2/11 fixtures | `ReadabilityExtractor.postProcess` | Quality | Backlog → E3 (~30 LOC designed fix) |
| 12 | Eval corpus is 11 fixtures; no NYT/Reuters/Medium/Substack, no paywall-pair or SPA fixtures | `Tests/Fixtures/extraction-corpus/` | Process | Backlog → E2 (target 30) |

Resource posture (already good, for the record): streamed downloads, per-clip scratch dir, 50 MB cumulative cap, 2048 px OCR downscale, 2 MB HTML cap, memoized `textContent`, single-parse Readability→Markdown handoff, JSON-LD bypass of Readability on hits.

## 4. P0 fixes shipped with this assessment

1. **FileSaver bookmark refresh** — refresh now happens synchronously while scoped access is held; persists via new `nonisolated ClipperSettings.persistVaultBookmark(_:)` (UserDefaults is thread-safe), logs on failure.
2. **OCR timeout** — `recognizeText` runs Vision off-actor in a detached task raced against a 30 s timeout with a lock-guarded exactly-once resume; on timeout the clip proceeds without OCR for that image.
3. **Regex hardening** — `<img>`/`<source>` patterns precompiled as statics (perf: compiled once, used at 4 call sites); all failure paths log.
4. **Fetch retry + honest errors** — `fetchHTML` retries transient failures (timeout/conn-reset/5xx/429, never paywall 4xx) with jittered exponential backoff, honors cancellation, throws typed `FetchError`; a URL-only share with no usable fallback content now surfaces *"Couldn't fetch the page — The page returned HTTP 403. Try opening it in Safari and sharing from there."* instead of silently failing or saving a stub.

## 5. Epic backlog summary

| # | Epic | Priority | Depends on |
|---|---|---|---|
| E1 | Never Lose a Clip — integrity & stability hardening | P0 | — |
| E2 | Measure What We Capture — eval corpus 11→30, paywall/AMP/SPA pairs | P0 | — |
| E3 | Clean Markdown Everywhere — recirc strip, single-parse, readability-jsc decision | P1 | E2 |
| E4 | Honest Capture Status — PaywallDetector + partial-clip UX | P1 | E2 |
| E5 | Smarter Re-fetch — backoff (shipped), desktop UA, AMP fallback | P1 | E4 |
| E6 | JS-Rendered Pages — WKWebView render tier (spike-gated) | P2 | E4 |
| E7 | Opt-In Archive Fallback — default-off, provenance frontmatter | P3 | E4 |

Sequencing: E1 ∥ E2 → E3, E4 → E5 → E6 ∥ E7. Every capture epic's definition-of-done is a fixture pass-rate delta on the E2 corpus (`eval/<approach>/summary.json`).

## 6. Where the backlog lives

Epics and stories are motes (`mote ls`, `mote progress <id>`), tagged `epic` + `capture`/`hardening`/`eval`, with `blocks`/`depends_on` edges encoding the sequencing above. Epic bodies carry the full BDD framing ("In order to / As a / I want" + Gherkin acceptance scenarios), including E5's explicit crawler-spoofing non-goal so the "why not" survives.

| Epic | Mote ID |
|---|---|
| E1 | `obsidian-clipper-Tdj7je2zz09jsg4uc` |
| E2 | `obsidian-clipper-Tdj7jeph2ds94h2vg` |
| E3 | `obsidian-clipper-Tdj7jeqa315zsojnm` |
| E4 | `obsidian-clipper-Tdj7jeqb66vzsoond` |
| E5 | `obsidian-clipper-Tdj7jeqc8aya84fop` |
| E6 | `obsidian-clipper-Tdj7jeqdajpk0rib7` |
| E7 | `obsidian-clipper-Tdj7jeqedwxm8y633` |

## 7. References

- PRD: `docs/PRD.md` · Architecture: `docs/ARCHITECTURE.md`
- Extraction approach comparison & merge rationale: `eval/comparison.md`, `eval/recommendation.md`
- Regression corpus: `Tests/Fixtures/extraction-corpus/` (`PipelineRegressionTests`, `ExtractionEvalTests`)
- Shelved escape hatch for extraction quality: branch `spike/readability-jsc` (Mozilla Readability.js in JSC, +25 MB resident — re-evaluate against the 30-fixture corpus per E3)
