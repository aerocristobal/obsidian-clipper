# Obsidian Clipper

An iOS app that clips web pages to your Obsidian vault as clean Markdown notes — complete with image extraction and OCR.

## Features

- **Share Extension** — available from Safari and any iOS app with a Share button
- **HTML → Markdown** — converts web content using Apple's native `NSAttributedString` HTML importer
- **Image Extraction** — downloads images from the page and saves them in an `images/` subfolder
- **OCR** — uses Apple's Vision framework (`VNRecognizeTextRequest`) to extract text from images
- **YAML Frontmatter** — optional metadata block with title, source URL, and clip date
- **Configurable Vault** — pick your vault folder and target subfolder from the settings screen
- **No Plugins Required** — writes `.md` files directly to your vault folder via iCloud Drive / Files

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

1. Select the **ObsidianClipper** target → Signing & Capabilities → + Capability → **App Groups**
2. Add: `group.com.obsidian.clipper`
3. Select the **ClipperExtension** target → repeat steps 1-2 with the same group ID
4. Update the bundle identifiers to match your development team

### 3. Build & Run

1. Select your device or simulator
2. Build the **ObsidianClipper** scheme (this builds both targets)
3. On first launch, configure your vault name and select the vault folder

### 4. Enable the Share Extension

The extension should appear automatically. If it doesn't:
1. Open Safari → visit any page → tap Share
2. Scroll right in the Share Sheet → tap "More"
3. Enable "Clip to Obsidian"

## Architecture

```
obsidian-clipper/
├── ObsidianClipper/              # Main app target
│   ├── ObsidianClipperApp.swift  # App entry point
│   ├── SettingsView.swift        # Configuration UI
│   ├── FolderPickerView.swift    # UIDocumentPicker wrapper
│   ├── AboutView.swift           # About screen
│   └── Assets.xcassets/          # App icon, accent color
│
├── ClipperExtension/             # Share Extension target
│   ├── ShareViewController.swift # Extension entry point & orchestrator
│   ├── ShareExtensionView.swift  # Progress/result SwiftUI view
│   ├── WebContentExtractor.swift # Extract URL/HTML/text from Share Sheet
│   ├── HTMLToMarkdown.swift      # HTML → Markdown converter
│   ├── ImageProcessor.swift      # Image download + Vision OCR
│   ├── FileSaver.swift           # Write .md + images to vault folder
│   ├── ClipResult.swift          # Data model for a clipped article
│   └── Info.plist                # Extension configuration
│
└── Shared/
    └── ClipperSettings.swift     # App Group UserDefaults (shared)
```

### Clipping Pipeline

```
Share Sheet → WebContentExtractor → HTMLToMarkdown
                                  → ImageProcessor (download + OCR)
                                  → ClipResult
                                  → FileSaver → vault/Inbox/article.md
                                              → vault/Inbox/images/image-1.png
```

## Output Format

Each clipped article produces:

```
Inbox/
├── Article Title.md
└── images/
    ├── image-1.png
    ├── image-2.jpg
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

Article content in clean Markdown...

![](images/image-1.png)

---

## Extracted Text (OCR)

### image-1.png

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
- On device: Settings → General → Profiles → trust your dev certificate
- Restart the device if the extension still doesn't appear

### "No vault folder configured" error
- Open the main Obsidian Clipper app
- Tap "Select Vault Folder" and navigate to your vault in iCloud Drive

### Images not downloading
- Some sites block image downloads from non-browser user agents
- Very large pages are limited to 20 images to avoid memory pressure in the extension

### OCR returns no text
- OCR works best on images with clear, printed text
- Photographs and diagrams may not yield useful text

## License

MIT
