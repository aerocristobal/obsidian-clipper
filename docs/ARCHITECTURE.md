# Obsidian Clipper — Architecture

**Version:** 1.0 (shipped) · 1.1 hardening in progress
**Last updated:** 2026-04-16
**Audience:** developers and reviewers working on the codebase

---

## 1. System overview

Obsidian Clipper is a two-target iOS application:

```
┌────────────────────────────────┐     ┌───────────────────────────────────┐
│  ObsidianClipper (main app)    │     │  ClipperExtension (Share Extension)│
│                                │     │                                   │
│  • Onboarding + settings UI    │     │  • Receives shared content        │
│  • Vault folder picker         │     │  • Runs the clipping pipeline     │
│  • About screen                │     │  • Writes to the vault folder     │
└───────────────┬────────────────┘     └───────────────┬───────────────────┘
                │                                      │
                └────────────── App Group ─────────────┘
                      group.com.obsidian.clipper
                      (shared UserDefaults,
                       security-scoped bookmark)

                                    │
                                    ▼
                            ┌───────────────┐
                            │  Vault folder │
                            │  (iCloud Drive│
                            │   or local)   │
                            └───────────────┘
```

- The **main app** is a thin SwiftUI settings surface. It never clips — its job is to configure the vault bookmark and toggle clipping options.
- The **share extension** is where all clipping logic lives. It runs in a separate process with a tight memory budget (~120 MB) and must be resilient to being killed by the OS at any time.
- Both targets share settings via an **App Group**. The security-scoped bookmark persisted by the main app is re-resolved by the extension each time it runs.

---

## 2. Targets and modules

### 2.1 `ObsidianClipper/` — main app

| File | Responsibility |
|---|---|
| `ObsidianClipperApp.swift` | `@main` SwiftUI `App` entry. Injects a `ClipperSettings` into the environment. |
| `SettingsView.swift` | Form-based UI with an onboarding banner when no vault is set; shows a green/red vault-reachability indicator. |
| `FolderPickerView.swift` | `UIViewControllerRepresentable` wrapper around `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`. |
| `AboutView.swift` | Credits + version info. |
| `Assets.xcassets/` | App icon + accent color. |
| `ObsidianClipper.entitlements` | App Group entitlement only. |

### 2.2 `ClipperExtension/` — Share Extension

| File | Responsibility |
|---|---|
| `Info.plist` | Extension manifest. Activation rule matches `public.url`, `public.plain-text`, `public.html`, `public.image`. Declares `Action.js` as `NSExtensionJavaScriptPreprocessingFile`. Has `NSAllowsArbitraryLoads` to allow clipping from HTTP sites. |
| `Action.js` | Runs in Safari's page context; returns `{title, URL, html}` to the extension. |
| `ShareViewController.swift` | Extension principal class. Hosts the SwiftUI UI, owns the clipping `Task`, registers for memory warnings, guarantees single completion. |
| `ShareExtensionView.swift` | SwiftUI progress/success/error screen driven by `ShareViewModel`. |
| `WebContentExtractor.swift` | Pulls URL/HTML/text/images out of the `NSExtensionContext`. Falls back to fetching the page itself if only a URL is present. Handles `<meta charset>` detection. |
| `ReadabilityExtractor.swift` | Mozilla Readability-inspired DOM scorer. Also contains the shared `HTMLParser` and `HTMLNode` types used by the Markdown converter. |
| `HTMLToMarkdown.swift` | Tree-walking DOM → Markdown renderer. Also owns the `[[IMG:N]]` marker injection that preserves image positions across Readability and conversion. |
| `ImageProcessor.swift` | Actor. Downloads images to a per-instance scratch directory, runs Vision OCR, enforces per-clip cumulative size cap, throttles on memory warnings. |
| `FileSaver.swift` | Resolves the security-scoped bookmark, creates the per-article subfolder, moves scratch images into place, writes the `.md`. |
| `ClipResult.swift` | Value type that assembles final Markdown (frontmatter + body + image appendix + OCR appendix). |
| `ClipperExtension.entitlements` | App Group entitlement only. |

### 2.3 `Shared/` — shared between both targets

| File | Responsibility |
|---|---|
| `ClipperSettings.swift` | `@MainActor` `ObservableObject` backed by App Group `UserDefaults`. Exposes the vault bookmark, vault name, target folder, and feature toggles. The bookmark resolution helpers are `nonisolated` and `Sendable`-safe so the extension can call them from any context. |

### 2.4 `ObsidianClipperTests/` — unit tests

| File | Approx. tests |
|---|---|
| `HTMLToMarkdownTests.swift` | Converter behavior, marker injection, `srcset` parsing, safety filters |
| `ReadabilityExtractorTests.swift` | Candidate scoring, title cleaning, inline-link preservation, link-density edge cases |
| `WebContentExtractorTests.swift` | Encoding detection, URL-in-text detection, scheme rejection |
| `ImageProcessorTests.swift` | Magic-byte sniffing, cumulative size cap, scheme rejection |
| `FileSaverTests.swift` | Filename sanitization incl. Windows reserved names, Unicode |
| `ClipResultTests.swift` | YAML sanitization, frontmatter emission, image/OCR appendix |

Total ~170 tests at time of writing.

---

## 3. The clipping pipeline

Orchestrated by `ShareViewController.performClipping()`:

```
  NSExtensionContext
         │
         ▼
  ┌──────────────────────────┐
  │  WebContentExtractor     │   URL? HTML? plainText? sharedImages?
  │  - detects charset       │
  │  - fetches URL-only shares│
  │  - URL-in-text detection  │
  └────────────┬─────────────┘
               │ RawContent {title, url, html?, plainText?, sharedImages[]}
               ▼
  ┌──────────────────────────┐
  │  HTMLToMarkdown          │
  │  .replaceImgTagsWith     │   Injects [[IMG:0]], [[IMG:1]], …
  │   Markers()              │   Builds markerMap: Int → URL
  └────────────┬─────────────┘
               │ (markedHTML, markerMap)
               ▼
  ┌──────────────────────────┐
  │  ReadabilityExtractor    │
  │  .extract(html:url:)     │   Picks winning article subtree.
  │                          │   Returns articleNode + title + excerpt.
  └────────────┬─────────────┘
               │ ReadabilityResult { articleNode, title, ... }
               │        │ if result is nil or < 100 non-whitespace chars,
               │        │ fall back to full HTML parse.
               ▼
  ┌──────────────────────────┐
  │  HTMLToMarkdown          │
  │  .convert(node:) or      │   Tree-walking renderer.
  │  .convert(html:)         │
  └────────────┬─────────────┘
               │ markdown with [[IMG:N]] markers
               ▼
  ┌──────────────────────────┐
  │  ImageProcessor (actor)  │
  │  .process(urls:)         │   Streams to scratch dir;
  │  or                      │   runs Vision OCR.
  │  .processSharedImages()  │
  └────────────┬─────────────┘
               │ [ExtractedImage { sourceURL, tempFileURL, filename, ocrText? }]
               ▼
  ┌──────────────────────────┐
  │  HTMLToMarkdown          │
  │  .replaceMarkersWith     │   Swaps [[IMG:N]] → ![alt](images/…).
  │   Images()               │
  └────────────┬─────────────┘
               │ final markdown body
               ▼
  ┌──────────────────────────┐
  │  ClipResult              │   Assembles frontmatter + body +
  │                          │   orphan images appendix + OCR appendix.
  └────────────┬─────────────┘
               ▼
  ┌──────────────────────────┐
  │  FileSaver.save()        │   Resolves bookmark, starts scoped access,
  │                          │   creates per-article folder,
  │                          │   moves scratch images into images/,
  │                          │   writes .md, stops scoped access.
  └────────────┬─────────────┘
               ▼
         success UI → auto-dismiss after 1.5s
```

`Task.checkCancellation()` is called between every stage. On cancel:

1. The clipping task is cancelled.
2. The `ImageProcessor`'s scratch directory is removed asynchronously.
3. `extensionContext.cancelRequest(withError: ClipError.cancelled)` is called.
4. `didComplete` (guarded by `NSLock`) prevents double-completion.

---

## 4. Key design decisions

### 4.1 Why a tree-based HTML → Markdown converter?

The original v1.0 converter used `NSAttributedString(data:options:documentAttributes:)` to parse HTML, then walked the attributed string inspecting font traits, paragraph styles, and `NSTextList` attributes to emit Markdown. In the Share Extension's memory-constrained environment, the HTML importer silently truncated or dropped content on long articles, producing notes that contained only the title and a blockquote link.

**Decision** (commit `9356534`): replace `NSAttributedString` entirely with a pure-Swift tree-walking renderer built on the same `HTMLParser` used by `ReadabilityExtractor`. This eliminated UIKit dependency, removed the silent-truncation failure mode, made the converter deterministic, and allowed unit testing without a UIKit runtime.

### 4.2 Why a custom HTML parser instead of `SwiftSoup` or `libxml2`?

- **SwiftSoup** was considered and briefly used but pulls in a non-trivial dependency and has its own memory characteristics.
- **libxml2** would complicate the build and force bridging between C strings and Swift.
- The pages we care about are real-world HTML — not spec-compliant — and a recursive-descent parser that handles the common malformations (implicit closing tags, unquoted attributes, `<br><br>` chains, raw-text `<script>`/`<style>` content) is enough. Story 4.1 converted it to byte-level UTF-8 iteration for CJK performance.

### 4.3 Why reuse one parse across Readability and Markdown?

Story 2.1 changed `ReadabilityExtractor.extract` to return the winning `HTMLNode` directly (not a serialized HTML string), and `HTMLToMarkdown` gained a `convert(node:)` overload. The old pipeline parsed the HTML twice — once for Readability, once for Markdown — which cost time proportional to article size. The new pipeline parses once and walks the tree.

### 4.4 Why inline image markers?

Before markers, the pipeline batched images at the bottom of each note (`## Images`). This produced notes where a figure and its caption were separated by the full article body. The marker system:

1. `replaceImgTagsWithMarkers(html)` replaces each `<img>` (and `<source>`) with `[[IMG:N]]` as plain text before Readability runs.
2. The markers survive Readability's mutation and the tree-based converter's rendering (they're just text nodes).
3. `replaceMarkersWithImages(markdown, markerToPath)` swaps `[[IMG:N]]` for `![alt](path)` once the images have been downloaded and their final filenames are known.
4. Any marker whose URL didn't download successfully remains in the Markdown as `[[IMG:N]]` — intentionally surfacing the gap rather than silently hiding it.
5. Unreferenced images (e.g. shared directly, not linked in HTML) fall back to the `## Images` appendix.

### 4.5 Why stream images to disk?

Story 4.5 replaced `ExtractedImage.data: Data` with `ExtractedImage.tempFileURL: URL`. Previously the extension held downloaded image bytes in memory until the save step, which combined with Vision's `.accurate` OCR (2–5 MB per image during the request) could push the extension past its budget on image-heavy pages.

Now:
- `URLSession.download(from:)` writes straight to a system temp file.
- `ImageProcessor` moves (or copies on cross-volume) the file into its own scratch directory (`NSTemporaryDirectory() + clipper-<UUID>`).
- `FileSaver.save` uses `FileManager.moveItem` to relocate the file into the vault's `images/` directory.
- OCR opens the file from disk inside an `autoreleasepool`, keeping the `UIImage` and downscaled `CGImage` lifecycles tight.
- On success or cancel, the scratch directory is removed wholesale.

### 4.6 Why throttle concurrency on memory warnings?

Story 4.7: the extension registers for `UIApplication.didReceiveMemoryWarningNotification`. When a warning arrives mid-clip, `ShareViewController` hops onto the image-processor actor and calls `reduceConcurrency()`, which lowers `maxConcurrent` from 3 to 1. Already-running tasks finish normally; only *new* tasks are gated. The refill loops in `process(urls:)` and `processSharedImages` re-check the cap each iteration, so the throttle takes effect immediately. Idle-state warnings are a no-op (processor is nil).

### 4.7 Why penalize link-density at the aggregated score?

The original Readability implementation penalized link-density per-element. On pages where the article body is split across many small sibling containers (e.g. Wired's `ArticlePageChunks` layout, where `BodyWrapper` divs are interleaved with ad slots), a "More from Publisher" related-articles grid could beat the actual body: each summary card had moderate individual score, but once propagated to the grid parent, the sum outscored any single body chunk.

**Fix** (commit `a321bcc`): at winner selection, multiply each candidate's final score by `max(0.05, 1.0 - linkDensity)`. Article bodies (density < 0.1) keep >90% of their score; link-card grids (density > 0.6) lose half or more. Single stray links can't zero out a real candidate thanks to the clamp.

### 4.8 Why preserve inline tags inside paragraphs during post-processing?

Before commit `818185a`, `postProcess` recursively scanned every descendant and removed any child with `linkDensity > 0.5 && text.count < 200`. Recursing into a `<p>` meant every inline `<a>` (density 1.0, short text) was treated as a removable high-link-density block, leaving mid-sentence gaps.

**Fix**: introduce an `inlineTags` set (`a, span, em, strong, b, i, u, s, code, mark, sub, sup, cite, abbr, time, ...`) that is skipped during removal, and an `inlineContentContainers` set (`p, h1-h6, li, blockquote, pre, figcaption, ...`) that short-circuits the recursion. Additionally, negative class/id patterns (`"ad"`, `"nav"`, etc.) are matched on word boundaries so `"lead-in-text-callout"` no longer false-matches `"ad"`.

### 4.9 Why per-article subfolders?

Commit `af5be09`: each clip lives in its own folder (`<Vault>/<Target>/<Title>/`). This means a clip is **movable as a unit** — drag it in Obsidian to reorganize and the images come along. It also sidesteps filename collisions between images from different clips (the short hash prefix still exists as belt-and-braces).

### 4.10 Why a tight security model at ingress?

All URL-producing paths reject non-`http(s)` schemes:

- `WebContentExtractor.fetchHTML` and `isAllowedScheme`
- `ImageProcessor.isFetchableScheme`
- `HTMLToMarkdown.replaceImgTagsWithMarkers` and `extractImageURLs`
- `HTMLToMarkdown`'s link renderer strips `javascript:`, `data:`, `vbscript:` and percent-encodes parentheses in safe URLs

This prevents SSRF-style tricks where a malicious page's `src="file:///etc/passwd"` or `src="javascript:…"` could coerce the extension into reading local files or embedding active content.

### 4.11 Why YAML value sanitization?

`ClipResult.toMarkdown` normalizes title whitespace (collapsing newlines/tabs/CR into single spaces) and escapes backslashes, double quotes, newlines, CR, and tabs in YAML values. Without this, a page whose `<title>` contained a literal newline could break the frontmatter and silently corrupt subsequent YAML keys.

---

## 5. Concurrency model

The codebase is strict-Sendable clean.

### 5.1 Actor boundaries

| Type | Isolation |
|---|---|
| `ClipperSettings` | `@MainActor` (all property access on main). `resolveVaultURL()` and `resolveVaultBookmark(_:)` are `nonisolated static`. |
| `ClipperSettings.ResolvedVault` | `Sendable` struct. |
| `ClipResult`, `ExtractedImage` | `Sendable` struct. |
| `FileSaver.SaveConfig` | `Sendable` struct; extracts values from `ClipperSettings` on `@MainActor` and can be passed to the `nonisolated` `FileSaver.save`. |
| `ImageProcessor` | `actor`. All mutable state (`maxConcurrent`, `inFlightCount`, `totalBytesDownloaded`, `scratchDirectory`) is actor-isolated. |
| `ShareViewModel` | `@Observable @MainActor`. |
| `ShareViewController` | `final class` (UIKit, main). |
| `HTMLNode` | `@unchecked Sendable`. Rationale: the tree is built synchronously by `HTMLParser.parse()`, all mutation (`preprocess`, `postProcess`) completes on the calling actor before the tree is handed off for scoring, and the `_cachedTextContent` memoization field is only written during sequential tree traversal. No cross-actor concurrent mutation occurs. |

### 5.2 Completion / cancel safety

`ShareViewController` guards the extension's completion with an `NSLock` around `didComplete`. `trySetComplete()` atomically checks-and-sets the flag so success and cancel paths can both race to complete but only one wins. On cancel:

- `clippingTask.cancel()` is called.
- The `imageProcessor`'s scratch directory is scheduled for removal in a detached task.
- `extensionContext.cancelRequest` tears down the extension.

### 5.3 Memory-warning handler

The memory-warning observer is a block-based `NotificationCenter` observer, which means its token must be explicitly retained and released. `ShareViewController` keeps the token in `memoryWarningObserver` and removes it in `deinit`.

### 5.4 OCR continuation safety

`ImageProcessor.recognizeText(in:)` uses `withCheckedContinuation`. The original implementation had a double-resume bug (commit `dc69b72`): both the error path and the observations path could call `continuation.resume` if `request.results` was both nil and had an error. The fix guards the entire observations branch with `guard error == nil, let observations = ... as? [VNRecognizedTextObservation]` so exactly one resume happens.

---

## 6. Memory strategy

The Share Extension has a ~120 MB resident memory cap. Violating it results in immediate OS termination. Mitigations:

1. **Stream image downloads to disk.** `URLSession.download` + `moveItem` to scratch directory. No in-memory `Data` blob.
2. **Per-instance scratch directory.** Cleaned up wholesale on success or cancel.
3. **Cumulative image cap.** 50 MB per clip (test-overridable). Oversized singles and cap-exceeders are dropped gracefully — smaller later images still process.
4. **Vision input downscaling.** Images with a longest edge > 2048 px are resized before OCR. `UIGraphicsImageRenderer` with `format.scale = 1` guarantees we downscale to pixel units, not points.
5. **Autoreleasepools around UIKit intermediaries.** `UIImage(contentsOfFile:)` and `CGImage` creation sit inside `autoreleasepool` so they are released at the end of each task rather than piling up until the actor quiesces.
6. **Scoped HTML strings.** `ShareViewController.performClipping()` wraps the large `markedHTML` string in a `do` block so ARC releases it before image processing starts.
7. **Detached article tree from document.** `ReadabilityExtractor` nils the winner's `parent` pointer so ARC can release the rest of the document tree.
8. **`textContent` memoization with invalidation.** `HTMLNode._cachedTextContent` avoids O(n²) recomputation during scoring; cache is invalidated up the parent chain on mutation.
9. **UTF-8 byte-buffer HTML parser.** Story 4.1 replaced the `String.Index` walker with `ContiguousArray<UInt8>` + `Int` offsets. No per-`peekString` allocation; text/attribute byte ranges are decoded to `String` only once at emission.
10. **Memory-warning throttle.** Drops image-processing concurrency from 3 to 1 when iOS posts a warning.
11. **20-image cap per clip.** Hard limit in `performClipping`.
12. **10-image cap for shared images.** Hard limit in `processSharedImages`.
13. **2 MB HTML cap.** `HTMLToMarkdown.convert` truncates overlong HTML rather than attempting to parse pathological documents.

---

## 7. Security boundaries

| Boundary | Enforcement |
|---|---|
| Fetching external URLs | Only `http(s)`. Rejected in `WebContentExtractor.isAllowedScheme` and `ImageProcessor.isFetchableScheme`. |
| Links rendered into Markdown | `javascript:`, `data:`, `vbscript:` schemes stripped (text-only fallback). Parentheses percent-encoded. |
| Image URLs in HTML | `data:` URLs rejected; tracking pixels and SVGs skipped by heuristic. |
| YAML frontmatter | Values are double-quoted and escape backslash, double-quote, `\n`, `\r`, `\t`. Title whitespace is collapsed so control characters can't break YAML. |
| Filename injection | `sanitizeFilename` removes `/:*?"<>|\`, collapses dashes, strips leading/trailing dots, caps at 200 chars, suffixes Windows-reserved names with `_`. |
| Vault file I/O | Bracketed by `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`. Stale bookmarks are refreshed in-scope. |
| User-agent | Fixed mobile Safari string. No identifying data. |

---

## 8. Testing strategy

### 8.1 Unit tests

~170 tests in 6 files under `ObsidianClipperTests/`. Runs against the `iPhone 16` simulator via `xcodebuild -scheme ObsidianClipper test`. The test target imports the extension's sources directly (configured via the test target's Sources build phase) so `@testable import ObsidianClipper` resolves symbols from the extension.

### 8.2 Regression fixtures

`ReadabilityExtractorTests` contains self-contained regression fixtures for real layouts that once produced bad output:

- Wired `ArticlePageChunks` — must pick the chunked body, not the related-articles grid.
- Wired horror-movie review — must not pick the `SummaryCollectionGridItems` sidebar.
- Slate, Electrek — typical `<article>` / `<main>` wrappers.
- Inline-link preservation — `<p>` with inline `<a>` must not have its links stripped.
- Negative-pattern word-boundary check — `"lead-in-text-callout"` must not false-match `"ad"`.

### 8.3 Manual testing

Required for:

- Actual Share Sheet integration (can't be exercised in XCTest).
- Memory-pressure behavior on device (can be simulated but best verified on-device).
- Security-scoped bookmark lifecycle across app kills and iOS restarts.
- iCloud Drive sync timing.

---

## 9. Build and run

See `CLAUDE.md` for canonical commands. Summary:

```bash
# Build both targets
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The main app scheme `ObsidianClipper.xcscheme` is checked in with a configured test action so Xcode Cloud and local runs share the same configuration.

---

## 10. Outstanding architectural risks

| Risk | Mitigation / status |
|---|---|
| **The custom HTML parser is not spec-compliant.** Pathological HTML may produce a malformed tree. | The parser handles the common real-world patterns and the Readability scorer is robust to missing children. Edge cases are captured as regression tests when they surface. |
| **Readability scoring is a heuristic.** Some layouts may still lose to recirc widgets. | The 100-char Markdown threshold triggers a full-HTML fallback when Readability's pick is clearly too narrow. |
| **Vision OCR latency on long pages with many images** can push total clip time toward the user-perceptible limit. | Concurrency cap of 3; cumulative image cap of 50 MB; downscale-before-OCR; 20-image hard cap. |
| **Security-scoped bookmark staleness across iCloud Drive reorgs.** | `FileSaver.save` detects staleness and schedules an in-scope refresh; next clip picks up the new bookmark. |
| **Strict-Sendable drift** as new Swift concurrency warnings are introduced in future Xcode releases. | Build settings keep strict concurrency on; the CI build fails on new warnings. |
| **`@unchecked Sendable` on `HTMLNode`** is a load-bearing assumption — any future code that shares a node across actors concurrently would violate it. | Documented at the declaration site. Code review should flag any cross-actor HTMLNode use. |

---

## 11. Glossary

- **App Group** — iOS mechanism for sharing data (UserDefaults, files) between a main app and its extensions. Here: `group.com.obsidian.clipper`.
- **Security-scoped bookmark** — an opaque `Data` blob from `URL.bookmarkData()` that encodes file-system access permission granted by the user via the document picker. Must be re-resolved and bracketed by `startAccessingSecurityScopedResource` on each use.
- **Readability** — Mozilla's open-source article-extraction algorithm. We ship an independent Swift reimplementation inspired by it, not a port.
- **Marker / `[[IMG:N]]`** — placeholder text injected in place of `<img>` tags before Readability extraction, swapped back for `![alt](path)` after images are downloaded. Survives HTML mutation because it's a plain text node.
- **Scratch directory** — a per-`ImageProcessor` temporary directory under `NSTemporaryDirectory()`. Holds downloaded and shared images until `FileSaver` moves them into the vault.
- **Action.js** — Safari JavaScript preprocessing file that captures the live page DOM and hands it to the extension.
