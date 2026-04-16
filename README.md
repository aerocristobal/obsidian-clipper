# Obsidian Clipper

An iOS app that clips web pages to your Obsidian vault as clean Markdown notes — complete with image extraction and OCR.

## Features

- **Share Extension** — available from Safari and any iOS app with a Share button
- **Safari JavaScript Preprocessing** — uses `Action.js` to capture the full page DOM directly from Safari, preserving authenticated content and avoiding re-fetching
- **HTML to Markdown** — comprehensive converter supporting:
  - Bold, italic, bold-italic, strikethrough
  - Headings (h1 through h4, smart font-size detection)
  - Ordered and unordered lists (via NSTextList detection)
  - Blockquotes (via paragraph indent detection)
  - Code blocks and inline code (monospace font detection)
  - Tables (tab-separated content detection and formatting)
  - Links with full URL preservation
- **Image Extraction** — downloads images from the page and saves them in an `images/` subfolder
  - Supports `srcset` (picks the largest image)
  - Supports lazy-load attributes: `data-src`, `data-lazy-src`, `data-original`
  - Parses `<picture>` / `<source>` elements
  - Automatic URL deduplication
  - 15-second download timeout per image
- **OCR** — uses Apple's Vision framework (`VNRecognizeTextRequest`) to extract text from images
- **YAML Frontmatter** — optional metadata block with title, source URL, and clip date
- **Configurable Vault** — pick your vault folder and target subfolder from the settings screen
- **First-Launch Onboarding** — guided setup when no vault is configured, with vault status indicator
- **No Plugins Required** — writes `.md` files directly to your vault folder via iCloud Drive / Files
- **Strict Concurrency** — `@MainActor`-isolated settings, `Sendable` types, clean actor boundaries

## Requirements

- iOS 17.0+
- Xcode 15.4+
- An Obsidian vault synced via iCloud Drive (or stored locally in Files)

## Setup

### 1. Clone and Open

```bash
git clone https://github.com/aerocristobal/obsidian-clipper.git
cd obsidian-clipper
open ObsidianClipper.xcodeproj
```

### 2. Configure App Group

Both the main app and the share extension need a shared App Group to access the same settings:

1. Select the **ObsidianClipper** target -> Signing & Capabilities -> + Capability -> **App Groups**
2. Add: `group.com.obsidian.clipper`
3. Select the **ClipperExtension** target -> repeat steps 1-2 with the same group ID
4. Update the bundle identifiers to match your development team

### 3. Build & Run

1. Select your device or simulator
2. Build the **ObsidianClipper** scheme (this builds both targets)
3. On first launch, the onboarding banner guides you to select your vault folder

### 4. Enable the Share Extension

The extension should appear automatically. If it doesn't:
1. Open Safari -> visit any page -> tap Share
2. Scroll right in the Share Sheet -> tap "More"
3. Enable "Clip to Obsidian"

## Sharing from Any App

The Share Extension works from **any iOS app**, not just Safari. What you get depends on the source:

| Source App | What's Shared | What Obsidian Clipper Does |
|-----------|--------------|--------------------------|
| **Safari** | Full page DOM via JavaScript preprocessing | Readability extraction, clean Markdown, images + OCR |
| **Twitter/X, Reddit, News** | URL | Fetches the page, extracts article, converts to Markdown |
| **Messages, Notes** | URL or plain text | Detects URLs in text and fetches the page; saves plain text directly |
| **Mail** | URL | Fetches and clips the linked page |
| **RSS Readers** | URL or HTML | Uses provided HTML or fetches from URL |
| **Photos, Screenshots** | Images | Saves images with OCR text extraction |

When an app shares a URL as plain text (common with Twitter, Reddit, and other social apps), Obsidian Clipper automatically detects it and fetches the linked page.

## Architecture

```
obsidian-clipper/
├── ObsidianClipper/              # Main app target
│   ├── ObsidianClipperApp.swift  # App entry point
│   ├── SettingsView.swift        # Configuration UI + onboarding
│   ├── FolderPickerView.swift    # UIDocumentPicker wrapper
│   ├── AboutView.swift           # About screen
│   └── Assets.xcassets/          # App icon, accent color
│
├── ClipperExtension/             # Share Extension target
│   ├── ShareViewController.swift # Extension entry point + @Observable view model
│   ├── ShareExtensionView.swift  # Progress/result SwiftUI view
│   ├── WebContentExtractor.swift # Extract URL/HTML/text from Share Sheet
│   ├── HTMLToMarkdown.swift      # HTML → Markdown converter (lists, code, tables, etc.)
│   ├── ImageProcessor.swift      # Image download + Vision OCR (with timeouts)
│   ├── FileSaver.swift           # Write .md + images to vault folder
│   ├── ClipResult.swift          # Data model for a clipped article
│   ├── Action.js                 # Safari JavaScript preprocessing
│   └── Info.plist                # Extension configuration + ATS exception
│
├── Shared/
│   └── ClipperSettings.swift     # @MainActor App Group UserDefaults (shared)
│
└── ObsidianClipperTests/         # Unit tests
    ├── HTMLToMarkdownTests.swift  # Converter + image extraction tests
    ├── FileSaverTests.swift       # Filename sanitization tests
    └── ClipResultTests.swift      # Markdown generation tests
```

### Clipping Pipeline

```
Any App → Share Sheet
    → WebContentExtractor (URL/HTML/text/images, URL-in-text detection, charset detection)
    → ReadabilityExtractor (article isolation, Safari: full DOM via Action.js)
    → HTMLToMarkdown (lists, code, blockquotes, tables, headings)
    → ImageProcessor (download + OCR, direct image OCR, srcset/lazy-load support)
    → ClipResult (Markdown assembly with image references)
    → FileSaver → vault/Inbox/article.md
                → vault/Inbox/images/image-1.png
```

### Safari JavaScript Preprocessing

The `Action.js` file runs in Safari's context before the share extension loads. It extracts:
- `document.title` — the page title
- `window.location.href` — the current URL
- `document.documentElement.outerHTML` — the full page DOM

This means the extension receives the exact page content the user sees, including:
- Content behind login walls (the user's session is active)
- Dynamically loaded content (JavaScript has already executed)
- The correct URL (after any redirects)

Without `Action.js`, the extension would need to re-fetch the page via `URLSession`, losing authenticated content and potentially getting different content (mobile redirects, paywalls, etc.).

## Markdown Conversion

The HTML-to-Markdown converter uses Apple's `NSAttributedString` HTML importer to parse the page, then walks the attributed string to emit Markdown syntax. It handles:

| Element | Detection Method | Markdown Output |
|---------|-----------------|-----------------|
| Bold | `UIFont` bold trait | `**text**` |
| Italic | `UIFont` italic trait | `_text_` |
| Bold+Italic | Both traits | `***text***` |
| Strikethrough | `.strikethroughStyle` attribute | `~~text~~` |
| Links | `.link` attribute | `[text](url)` |
| H1-H4 | Font size thresholds (32/26/22/18pt) | `# ` through `#### ` |
| Ordered lists | `NSTextList` with decimal format | `1. item` |
| Unordered lists | `NSTextList` with other formats | `- item` |
| Blockquotes | `NSParagraphStyle` headIndent >= 30 | `> text` |
| Code blocks | Monospace font, multi-line | ` ```code``` ` |
| Inline code | Monospace font, single-line | `` `code` `` |
| Tables | Tab-separated content (2+ rows) | Markdown table syntax |

Headings automatically suppress bold markers to avoid redundant `## **Title**` output.

## Output Format

Each clipped article produces:

```
Inbox/
├── Article Title.md
└── images/
    ├── abc-1.png
    ├── abc-2.jpg
    └── ...
```

The Markdown file contains:

```markdown
---
title: "Article Title"
source: "https://example.com/article"
clipped: 2026-04-13
type: article
---

# Article Title

> [Source](https://example.com/article) — Clipped 2026-04-13

Article content in clean Markdown with proper lists, code blocks,
blockquotes, and headings...

## Images

![image-1](images/abc-1.png)

---

## Extracted Text (OCR)

### abc-1.png

> Text recognized from the image via Apple Vision...
```

## Configuration

Settings are accessible from the main app:

| Setting | Description | Default |
|---------|-------------|---------|
| Vault Name | Name of your Obsidian vault | _(empty)_ |
| Target Folder | Subfolder within the vault for clips | `Inbox` |
| Vault Folder | The vault's root folder (picked via Files) | _(not set)_ |
| YAML Frontmatter | Include metadata at the top of each note | On |
| Save Images | Download images to an `images/` subfolder | On |
| OCR on Images | Run text recognition on downloaded images | On |

## Troubleshooting

### Extension doesn't appear in Share Sheet
- Make sure both targets build successfully
- On device: Settings -> General -> Profiles -> trust your dev certificate
- Restart the device if the extension still doesn't appear

### "No vault folder configured" error
- Open the main Obsidian Clipper app
- The onboarding banner will guide you to select your vault folder
- Check the green/red status indicator next to the vault location

### Images not downloading
- Some sites block image downloads from non-browser user agents
- Very large pages are limited to 20 images to avoid memory pressure in the extension
- Images have a 15-second download timeout; slow servers may be skipped

### OCR returns no text
- OCR works best on images with clear, printed text
- Photographs and diagrams may not yield useful text

### Content is garbled or has wrong characters
- The extension detects character encoding from the HTTP Content-Type header
- Supported encodings: UTF-8, ISO-8859-1/Latin-1, Windows-1252, ASCII, ISO-8859-2, UTF-16
- If a page uses an unsupported encoding, it falls back to UTF-8

### Extension captures different content than what you see
- For best results, share from Safari — the Action.js preprocessing captures the live DOM including authenticated content
- Sharing from other apps provides a URL that is re-fetched, which may show different content (paywalls, mobile redirects)
- Some apps share URLs as plain text — Obsidian Clipper detects these automatically

## Testing

The project includes a unit test target (`ObsidianClipperTests`) with tests for:
- `HTMLToMarkdown.convert()` — bold, italic, links, lists, blockquotes, code, headings, tables
- `HTMLToMarkdown.extractImageURLs()` — absolute/relative URLs, srcset, data-src, picture elements, dedup
- `FileSaver.sanitizeFilename()` — special characters, long names, empty names, unicode
- `ClipResult.toMarkdown()` — frontmatter generation, image references, OCR sections

## License

MIT
