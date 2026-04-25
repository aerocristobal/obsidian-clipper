import Foundation
@testable import ClipperExtension

/// Per-branch extraction adapter for the eval harness.
///
/// The harness in `ExtractionEvalTests.swift` calls `EvalEntryPoint.extract`
/// for every fixture. **This is the only file branches diverge on** —
/// each spike branch swaps the body of `extract` to route through its
/// own approach. The harness, fixtures, and scoring stay identical.
///
/// Contract:
/// - Input: raw HTML string + optional baseURL (for relative link resolution)
/// - Output: an `EvalResult` with markdown body, image URL count (or nil if
///   not measurable), and the title used.
///
/// The default (master) implementation runs the shipped pipeline:
/// `replaceImgTagsWithMarkers` → `ReadabilityExtractor.extract` →
/// `HTMLToMarkdown.convert(node:)`, then filters image markers to those
/// surviving Readability (mirroring what `ShareViewController` does).
enum EvalEntryPoint {

    struct EvalResult {
        let title: String
        let markdown: String
        /// Number of image markers that survived Readability (proxy for
        /// "images that would actually get downloaded"). nil if the
        /// approach doesn't go through marker injection.
        let imageMarkerCount: Int?
        /// Source label for the comparison report header.
        let approach: String
    }

    /// Identifier for the current branch. Each spike branch overrides this.
    static let approachName: String = "master"

    static func extract(html: String, baseURL: URL?) -> EvalResult {
        // 1. Inject image markers (matches the live pipeline)
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: baseURL)
        let markedHTML = markerResult.html

        // 2. Run Readability
        let readability = ReadabilityExtractor.extract(html: markedHTML, url: baseURL)

        let title: String
        let markdown: String
        let surviving: Set<Int>

        if let r = readability {
            let candidate = HTMLToMarkdown.convert(node: r.articleNode)
            // Match the live "<100 chars" fallback behavior in ShareViewController.
            if candidate.filter({ !$0.isWhitespace }).count >= 100 {
                markdown = candidate
                title = r.title ?? ""
                surviving = HTMLToMarkdown.findMarkerIndices(in: candidate)
            } else {
                markdown = HTMLToMarkdown.convert(markedHTML)
                title = r.title ?? ""
                surviving = HTMLToMarkdown.findMarkerIndices(in: markdown)
            }
        } else {
            markdown = HTMLToMarkdown.convert(markedHTML)
            title = ""
            surviving = HTMLToMarkdown.findMarkerIndices(in: markdown)
        }

        return EvalResult(
            title: title,
            markdown: markdown,
            imageMarkerCount: surviving.count,
            approach: approachName
        )
    }
}
