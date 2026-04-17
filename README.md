# Obsidian Clipper

An iOS app + Share Extension that clips web pages, text, and images into your [Obsidian](https://obsidian.md) vault as clean Markdown notes — with image extraction and OCR. No Obsidian plugin required.

> **Status:** v1.0 shipped, v1.1 hardening in progress. See [docs/PRD.md](docs/PRD.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

---

## What it does

- **Share from anywhere.** The extension shows up in every iOS app's Share Sheet, not just Safari.
- **Capture the live page.** In Safari, a JavaScript preprocessing file (`Action.js`) hands the extension the live DOM — authenticated content and dynamically loaded content included.
- **Extract the article.** A Mozilla Readability–inspired scorer picks the main content, excluding navigation, ads, sidebars, cookie banners, and related-articles grids.
- **Convert to Markdown.** A pure-Swift tree-walking renderer emits headings, lists, code blocks, blockquotes, tables, links, and inline images.
- **Pull in images.** `srcset`, `data-src`, `data-lazy-src`, `data-original`, and `<picture><source>` are all parsed. Images are streamed to disk to keep the extension under iOS's memory cap.
- **OCR screenshots.** Apple Vision (`VNRecognizeTextRequest`) extracts text from images and appends it as a blockquote.
- **Self-contained clips.** Each clip becomes a folder: `<Vault>/<Target>/<Article Title>/` with its own `images/` subfolder — move it in Obsidian and the images go with it.
- **Privacy-first.** Everything runs on-device. No server, no analytics, no telemetry.

---

## Feature list

### Clipping pipeline

- **Share Extension** activated on URLs, plain text, HTML, and images.
- **URL-in-text detection** — shares from X/Twitter, Reddit, Messages often arrive as plain text containing a URL; the extension auto-detects and fetches the page.
- **Character encoding detection** — uses Content-Type `charset=`, falls back to HTML `<meta charset>`, then UTF-8. Supports UTF-8, ISO-8859-1/2/15, Windows-1251/1252, ASCII, UTF-16, Shift_JIS, EUC-JP.
- **Readability-style article extraction** with link-density penalties at both per-element and aggregated scope.
- **Tree-based HTML → Markdown converter** built on a custom pure-Swift HTML parser that iterates over UTF-8 byte buffers (no `NSAttributedString`, no UIKit dependency, CJK-friendly performance).
- **Inline image placement** via `[[IMG:N]]` markers injected before Readability runs and swapped for `![alt](path)` after downloads complete.
- **YAML frontmatter** with sanitized values (escapes newlines, quotes, backslashes, tabs; collapses title whitespace to prevent YAML key injection).
- **Per-article subfolders** with a Unix-timestamp suffix on re-clip.
- **Sanitized filenames** — invalid characters replaced, Windows-reserved names (`CON`, `NUL`, `COM1-9`, `LPT1-9`) suffixed, leading/trailing dots stripped, length capped at 200 chars.

### Markdown conversion

| Element | Markdown output |
|---|---|
| `<h1>`–`<h6>` | `#` through `######` |
| `<strong>`, `<b>` | `**text**` |
| `<em>`, `<i>` | `_text_` |
| `<s>`, `<del>`, `<strike>` | `~~text~~` |
| `<code>` (inline) | `` `text` `` |
| `<pre>` / `<pre><code>` | fenced code block |
| `<ul>`, `<ol>`, `<li>` | nested `- ` / `1. ` with 2-space indent |
| `<blockquote>` | line-prefixed `> ` |
| `<table>` | Markdown table syntax |
| `<a href>` | `[text](url)` — `javascript:`, `data:`, `vbscript:` stripped, parens percent-encoded |
| `<img>` | `![alt](path)` placed inline at original position |
| `<br><br>` chains | paragraph break |
| `<hr>` | `---` |

### Safety and hardening

- **HTTP(S)-only** at every network ingress. `file://`, `javascript:`, `ftp:`, `data:` rejected.
- **Dangerous link schemes** stripped from Markdown output.
- **Memory-warning throttling** — `UIApplication.didReceiveMemoryWarningNotification` drops the image processor's concurrency cap from 3 to 1 mid-clip.
- **Streamed image downloads** — bytes go straight to a per-clip scratch directory on disk, never held in memory.
- **50 MB cumulative image cap** per clip with a per-image oversize check; smaller later images still process if an earlier one was too big.
- **Vision input downscaling** — images with a longest edge > 2048 px are resized before OCR.
- **Per-task autoreleasepools** around UIKit/CGImage intermediaries.
- **Security-scoped bookmarks** with in-scope stale refresh.
- **Task cancellation** checked between every pipeline stage.
- **Strict-Sendable clean** — `@MainActor` isolation on settings, `actor`-isolated image processor, `Sendable` value types crossing actor boundaries.
- **Double-completion guard** on the extension context (`NSLock` around `didComplete`).
- **`~170` unit tests** across 6 test files.

---

## Requirements

- iOS 17.0+
- Xcode 15.4+
- An Obsidian vault synced via iCloud Drive (or stored locally in Files)

---

## Setup

### 1. Clone and open

```bash
git clone https://github.com/aerocristobal/obsidian-clipper.git
cd obsidian-clipper
open ObsidianClipper.xcodeproj
```

### 2. Configure the App Group

Both targets need the same App Group so settings flow between them:

1. Select the **ObsidianClipper** target → Signing & Capabilities → + Capability → **App Groups**
2. Add `group.com.obsidian.clipper`
3. Repeat for the **ClipperExtension** target
4. Update bundle identifiers to match your development team

### 3. Build and run

1. Select your device or simulator (iPhone 16 recommended)
2. Build the **ObsidianClipper** scheme (builds both targets)
3. On first launch, follow the onboarding banner to pick your vault folder

### 4. Enable the Share Extension

It appears automatically. If it doesn't:

1. Open any app → tap Share
2. Scroll right in the Share Sheet → tap **More**
3. Enable **Clip to Obsidian**

---

## Sharing from any app

The extension works from any iOS app with a Share button. What you get depends on what the source shares:

| Source app | What's shared | What Obsidian Clipper does |
|---|---|---|
| **Safari** | Full page DOM via JavaScript preprocessing | Readability extraction + Markdown + images + OCR |
| **X/Twitter, Reddit, Mastodon, news apps** | URL | Fetches the page, extracts the article, saves Markdown |
| **Messages, Notes** | URL or plain text | Auto-detects URLs in text and fetches the page; plain text saved as-is |
| **Mail** | URL | Fetches and clips the linked page |
| **RSS readers** | URL or HTML | Uses provided HTML when available, else fetches from URL |
| **Photos, Screenshots** | Image(s) | Saves images with OCR-extracted text |

---

## Build and test

```bash
# Build (both targets)
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test class
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests test

# Run a single test method
xcodebuild -scheme ObsidianClipper \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ObsidianClipperTests/HTMLToMarkdownTests/testBoldConversion test
```

---

## Project layout

```
obsidian-clipper/
├── ObsidianClipper/              # Main app target (settings, onboarding)
│   ├── ObsidianClipperApp.swift
│   ├── SettingsView.swift        # Settings form + onboarding banner + vault status
│   ├── FolderPickerView.swift    # UIDocumentPicker wrapper
│   ├── AboutView.swift
│   ├── ObsidianClipper.entitlements
│   └── Assets.xcassets/
│
├── ClipperExtension/             # Share Extension (the real work)
│   ├── ShareViewController.swift     # Entry point; owns clipping Task, memory warnings, cancel
│   ├── ShareExtensionView.swift      # SwiftUI progress/success/error view
│   ├── WebContentExtractor.swift     # URL/HTML/text/image extraction, charset detection
│   ├── ReadabilityExtractor.swift    # DOM scorer, HTMLParser, HTMLNode
│   ├── HTMLToMarkdown.swift          # Tree-walking renderer, [[IMG:N]] markers
│   ├── ImageProcessor.swift          # Actor: download + OCR + scratch dir
│   ├── FileSaver.swift               # Per-article subfolder writer, bookmark refresh
│   ├── ClipResult.swift              # Frontmatter + body + appendix assembly
│   ├── Action.js                     # Safari JS preprocessing
│   ├── Info.plist                    # Activation rule, ATS, JS preprocessing ref
│   └── ClipperExtension.entitlements
│
├── Shared/
│   └── ClipperSettings.swift     # @MainActor App Group UserDefaults
│
├── ObsidianClipperTests/         # ~170 unit tests across 6 files
│   ├── HTMLToMarkdownTests.swift
│   ├── ReadabilityExtractorTests.swift
│   ├── WebContentExtractorTests.swift
│   ├── ImageProcessorTests.swift
│   ├── FileSaverTests.swift
│   └── ClipResultTests.swift
│
├── docs/
│   ├── PRD.md                    # Product requirements, user stories, success metrics
│   └── ARCHITECTURE.md           # Pipeline, design decisions, concurrency, memory, security
│
├── CLAUDE.md                     # Guidance for Claude Code when working in this repo
└── README.md
```

---

## Clipping pipeline

```
Share Sheet input
  → WebContentExtractor         (URL / HTML / text / images; charset detection; URL-in-text)
  → HTMLToMarkdown.replaceImgTagsWithMarkers   ([[IMG:N]] markers injected into HTML)
  → ReadabilityExtractor        (DOM scorer picks the article subtree)
  → HTMLToMarkdown.convert      (tree-walking Markdown renderer)
  → ImageProcessor              (stream-to-disk downloads + Vision OCR, actor-isolated)
  → HTMLToMarkdown.replaceMarkersWithImages    (swap markers for ![alt](path))
  → ClipResult                  (frontmatter + body + orphan images + OCR appendix)
  → FileSaver                   (scoped-resource access + per-article subfolder + write .md)
```

`Task.checkCancellation()` runs between every stage. On cancel, the image processor's scratch directory is removed and the extension context is cancelled cleanly.

---

## Safari JavaScript preprocessing

`Action.js` runs in Safari's page context before the extension loads and returns:

- `document.title`
- `window.location.href`
- `document.documentElement.outerHTML`

This captures the page the user actually sees — including content behind login walls, post-JavaScript hydration, and the real URL after any redirects. Without Action.js, the extension would have to re-fetch the URL and could get a different page (mobile redirects, paywall, rate limit).

---

## Output format

A clip produces:

```
Inbox/
└── Article Title/
    ├── Article Title.md
    └── images/
        ├── 3f2a-1.png
        └── 3f2a-2.jpg
```

Where the `.md` looks like:

```markdown
---
title: "Article Title"
source: "https://example.com/article"
clipped: 2026-04-16
type: article
---

# Article Title

> [Source](https://example.com/article) — Clipped 2026-04-16

Article body in clean Markdown with inline images...

![3f2a-1](images/3f2a-1.png)

...more paragraphs...

## Images

<!-- only populated for orphaned/unreferenced images -->

---

## Extracted Text (OCR)

### 3f2a-1.png

> Recognized text from the image via Apple Vision...
```

---

## Settings

| Setting | Description | Default |
|---|---|---|
| Vault Name | Display name of your Obsidian vault | _(empty)_ |
| Target Folder | Subfolder within the vault for clips | `Inbox` |
| Vault Folder | Root folder of the vault (picked via Files) | _(not set)_ |
| YAML Frontmatter | Include metadata block at top of each note | On |
| Save Images | Download images to an `images/` subfolder | On |
| OCR on Images | Run Vision text recognition on downloaded images | On |

---

## Troubleshooting

**Extension doesn't appear in the Share Sheet**
- Make sure both targets build successfully.
- On device: Settings → General → VPN & Device Management → trust your dev certificate.
- Scroll right in the Share Sheet → More → enable **Clip to Obsidian**.

**"No vault folder configured" error**
- Open Obsidian Clipper; the onboarding banner walks you through picking a vault folder.
- If the vault status dot is red, the bookmark is stale — re-pick the folder.

**Images not downloading**
- Some sites block non-browser user agents; the extension sends a mobile Safari UA but sites may still refuse.
- Per clip: 20 images max, 50 MB cumulative cap, 15-second per-image timeout.
- `.svg`, `data:` URLs, and tracking pixels are skipped intentionally.

**OCR returns no text**
- Vision works best on printed/rendered text. Photographs of objects and diagrams may not yield useful output.

**Content is garbled**
- Charset detection tries Content-Type → `<meta charset>` → UTF-8 fallback.
- If a page uses an unsupported encoding, it falls back to UTF-8 and may show mojibake.

**Extension captures different content than what you see**
- For best results share from Safari; Action.js captures the live DOM.
- Shares from other apps provide a URL that's re-fetched, which may hit a mobile redirect, paywall, or different cache.

**Extension crashes on large pages / image-heavy pages**
- The 2 MB HTML cap, 50 MB cumulative image cap, 20-image cap, Vision downscaling, and memory-warning throttle all exist to keep the extension under iOS's ~120 MB budget. File a report with the URL and a description of what you were clipping if you hit a crash despite these guards.

---

## Documentation

- [docs/PRD.md](docs/PRD.md) — Product requirements, user stories (BDD), success metrics, release history.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Pipeline, module responsibilities, concurrency model, memory strategy, security boundaries, key design decisions.
- [CLAUDE.md](CLAUDE.md) — Build/test commands and conventions for Claude Code when working in this repo.

---

## License

[MIT](LICENSE)
