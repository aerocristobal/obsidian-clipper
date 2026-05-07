import Foundation
import CryptoKit

// MARK: - Errors

/// Errors thrown by the clipping pipeline. Co-located with the pipeline so
/// the test target can compile the pipeline + its errors without dragging
/// in `ShareViewController` (which transitively requires SwiftUICore link
/// access that test bundles don't have).
enum ClipError: LocalizedError {
    case noContent
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "Could not extract content from the shared item. Try sharing a URL, text, or image."
        case .cancelled:
            return "Clipping was cancelled."
        }
    }
}

/// Pure-pipeline entry point for the share extension's clipping flow.
///
/// Why this is a free enum and not a method on `ShareViewController`:
/// `ShareViewController` owns a `ShareViewModel` whose `@Observable` macro
/// transitively pulls in SwiftUI/SwiftUICore type metadata. That's fine in
/// production but causes the test bundle to fail at link time with
/// "cannot link directly with 'SwiftUICore' because product being built is
/// not an allowed client of it" whenever a test references the VC. Lifting
/// the pipeline to a UI-free type keeps the harness tests linkable.
///
/// Production callers (`ShareViewController.performClipping`) supply the
/// real `extensionContext` plus closures that update the view model and
/// retain the active `ImageProcessor` for cancel/cleanup. Tests supply a
/// `FakeExtensionContext` and ignore the closures — they care about the
/// pipeline output (a `.md` file in the configured vault), not the
/// progress UI.
@MainActor
enum ClippingPipeline {

    /// Run the full extraction → markdown → save flow.
    ///
    /// - Parameters:
    ///   - extensionContext: the share-sheet input. Production passes
    ///     `self.extensionContext`; tests pass a `FakeExtensionContext`.
    ///   - onState: progress callback. Production binds to
    ///     `viewModel.state = .loading(_:)`. Tests typically pass `nil`.
    ///   - onImageProcessor: invoked when the pipeline allocates an
    ///     `ImageProcessor`, so a UI host can hold the reference for
    ///     cancellation/cleanup. Tests typically pass `nil`.
    /// - Returns: the article title (used by the VC for the success label).
    /// - Throws: `ClipError.noContent` when the share input is empty;
    ///   `FileSaver.SaveError` when the vault write fails;
    ///   `CancellationError` when the surrounding Task is cancelled.
    static func run(
        extensionContext: NSExtensionContext?,
        onState: ((String) -> Void)? = nil,
        onImageProcessor: ((ImageProcessor?) -> Void)? = nil
    ) async throws -> String {
        let settings = ClipperSettings()
        let saveConfig = FileSaver.SaveConfig(from: settings)

        onState?("Extracting content…")

        guard let context = extensionContext,
              let rawContent = await WebContentExtractor.extract(from: context) else {
            throw ClipError.noContent
        }

        try Task.checkCancellation()

        let isImageOnly = rawContent.html == nil
            && rawContent.url == nil
            && !rawContent.sharedImages.isEmpty

        var articleTitle = rawContent.title
        var markdownBody: String
        var markerMap: [Int: URL] = [:]

        if isImageOnly {
            onState?("Processing images…")
            markdownBody = ""
        } else if let html = rawContent.html {
            // Scope a `do` block so the large intermediate HTML string
            // (markedHTML) is released before image processing begins.
            do {
                if let ld = JSONLDExtractor.tryFastPath(html: html) {
                    NSLog("[Clipper.pipeline] JSON-LD fast path HIT; isHTML=%d body_len=%d title_len=%d",
                          ld.articleBodyIsHTML ? 1 : 0, ld.articleBody.count, ld.title.count)
                    onState?("Extracting article…")
                    let bodyHTML = ld.articleBodyIsHTML
                        ? ld.articleBody
                        : Self.wrapPlainTextAsHTML(ld.articleBody)
                    let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(bodyHTML, baseURL: rawContent.url)
                    markerMap = markerResult.markerMap
                    markdownBody = HTMLToMarkdown.convert(markerResult.html)
                    NSLog("[Clipper.pipeline] JSON-LD path: markerMap=%d markdown_len=%d", markerMap.count, markdownBody.count)
                    if !ld.title.isEmpty {
                        articleTitle = ld.title
                    }
                    try Task.checkCancellation()
                } else {
                    NSLog("[Clipper.pipeline] JSON-LD fast path MISS; falling through to Readability")
                    let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: rawContent.url)
                    markerMap = markerResult.markerMap
                    let markedHTML = markerResult.html

                    try Task.checkCancellation()

                    onState?("Extracting article…")
                    let readabilityResult = ReadabilityExtractor.extract(html: markedHTML, url: rawContent.url)

                    if let result = readabilityResult {
                        let candidateMarkdown = HTMLToMarkdown.convert(node: result.articleNode)
                        if candidateMarkdown.filter({ !$0.isWhitespace }).count >= 100 {
                            markdownBody = candidateMarkdown
                            if let extractedTitle = result.title, !extractedTitle.isEmpty {
                                articleTitle = extractedTitle
                            }
                        } else {
                            markdownBody = HTMLToMarkdown.convert(markedHTML)
                        }
                    } else {
                        markdownBody = HTMLToMarkdown.convert(markedHTML)
                    }

                    try Task.checkCancellation()
                }
            }
        } else if let plain = rawContent.plainText {
            onState?("Saving text…")
            markdownBody = plain
        } else {
            markdownBody = ""
        }

        try Task.checkCancellation()

        var images: [ExtractedImage] = []
        let prefix = Self.shortHash(title: rawContent.title, url: rawContent.url)

        if isImageOnly {
            onState?("Running OCR…")
            let processor = ImageProcessor()
            onImageProcessor?(processor)
            images = await processor.processSharedImages(
                rawContent.sharedImages,
                enableOCR: settings.enableOCR,
                prefix: prefix
            )
        } else if settings.saveImages, rawContent.html != nil {
            onState?("Processing images…")

            let surviving = HTMLToMarkdown.findMarkerIndices(in: markdownBody)
            let filteredMarkerMap = markerMap.filter { surviving.contains($0.key) }
            let limitedURLs = Array(filteredMarkerMap.values.prefix(20))
            NSLog("[Clipper.pipeline] image-block: markerMap=%d surviving=%d filtered=%d limited(<=20)=%d",
                  markerMap.count, surviving.count, filteredMarkerMap.count, limitedURLs.count)

            let processor = ImageProcessor()
            onImageProcessor?(processor)
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)

            var urlToPath: [String: String] = [:]
            for image in images {
                urlToPath[image.sourceURL.absoluteString] = "images/\(image.filename)"
            }

            var markerToPath: [Int: String] = [:]
            for (index, url) in filteredMarkerMap {
                if let path = urlToPath[url.absoluteString] {
                    markerToPath[index] = path
                }
            }
            NSLog("[Clipper.pipeline] image-block: downloaded=%d urlToPath=%d markerToPath=%d",
                  images.count, urlToPath.count, markerToPath.count)
            let inlineResult = HTMLToMarkdown.replaceMarkersWithImages(markdownBody, markerToPath: markerToPath)
            markdownBody = inlineResult.markdown
        } else if settings.saveImages {
            NSLog("[Clipper.pipeline] image-block: SKIPPED (saveImages=true but no html)")
        } else {
            NSLog("[Clipper.pipeline] image-block: SKIPPED (saveImages=false)")
        }

        try Task.checkCancellation()

        let clipResult = ClipResult(
            title: articleTitle,
            sourceURL: rawContent.url,
            markdownBody: markdownBody,
            images: images,
            clippedDate: Date()
        )

        onState?("Saving to vault…")
        try FileSaver.save(clipResult, config: saveConfig)

        // Note: the caller is responsible for cleaning up the
        // `ImageProcessor` it received via `onImageProcessor`. Production
        // (`ShareViewController`) does this in `done()` / `cancel()`.

        return rawContent.title
    }

    // MARK: - Helpers

    /// Short hex hash identifying a single clip; used as an image filename
    /// prefix so two clips with the same inferred indices do not overwrite
    /// each other.
    private static func shortHash(title: String, url: URL?) -> String {
        let seed = "\(title)|\(url?.absoluteString ?? "")|\(Date().timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Wrap a JSON-LD plain-text `articleBody` in `<p>` tags so it flows
    /// through `HTMLToMarkdown.convert` cleanly. Splits on `\n\n` when
    /// available, falls back to single `\n` (Wired emits the latter).
    private static func wrapPlainTextAsHTML(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.contains("\n\n") ? "\n\n" : "\n"
        let escape: (String) -> String = { s in
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        return normalized
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escape($0))</p>" }
            .joined(separator: "\n")
    }
}
