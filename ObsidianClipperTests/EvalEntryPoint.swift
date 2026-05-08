import Foundation
@testable import ClipperExtension

/// Eval harness extraction adapter.
///
/// On `main` (post-merge of B + C): JSON-LD fast path runs first; on miss,
/// falls through to the shipped Readability pipeline which now uses the
/// SwiftSoup parser underneath. Output goes to `eval/main/`.
enum EvalEntryPoint {

    struct EvalResult {
        let title: String
        let markdown: String
        let imageMarkerCount: Int?
        let approach: String
    }

    /// Identifier used for eval-output directory naming.
    static let approachName: String = "main"

    static func extract(html: String, baseURL: URL?) -> EvalResult {
        // 1. JSON-LD fast path — short-circuit when the publisher has
        //    embedded the article body as Schema.org structured data.
        if let ld = JSONLDExtractor.tryFastPath(html: html) {
            let (markdown, imageCount) = renderJSONLDBody(ld, baseURL: baseURL)
            return EvalResult(
                title: ld.title,
                markdown: markdown,
                imageMarkerCount: imageCount,
                approach: approachName
            )
        }

        // 2. Fallback — identical to master pipeline.
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: baseURL)
        let markedHTML = markerResult.html
        let readability = ReadabilityExtractor.extract(html: markedHTML, url: baseURL)

        let title: String
        let markdown: String
        let surviving: Set<Int>

        if let r = readability {
            let candidate = HTMLToMarkdown.convert(node: r.articleNode)
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

    // MARK: - JSON-LD body rendering

    /// Render a JSON-LD body to Markdown and count any image markers.
    /// HTML bodies pass through `HTMLToMarkdown.convert` after marker
    /// injection. Plain-text bodies (Wired, NYT) carry no inline markup,
    /// so we prepend a publisher-declared lead image (from JSON-LD's
    /// `image` field) before wrapping the prose in `<p>` tags. The same
    /// marker-injection + downloader handles both cases identically.
    private static func renderJSONLDBody(
        _ ld: JSONLDExtractor.Result,
        baseURL: URL?
    ) -> (markdown: String, imageCount: Int) {
        let bodyHTML: String
        if ld.articleBodyIsHTML {
            bodyHTML = ld.articleBody
        } else {
            bodyHTML = leadImageHTML(from: ld.imageURLs) + wrapPlainTextAsHTML(ld.articleBody)
        }

        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(bodyHTML, baseURL: baseURL)
        let markdown = HTMLToMarkdown.convert(markerResult.html)
        let surviving = HTMLToMarkdown.findMarkerIndices(in: markdown)
        return (markdown, surviving.count)
    }

    private static func wrapPlainTextAsHTML(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.contains("\n\n") ? "\n\n" : "\n"
        let paragraphs = normalized
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
    }

    private static func leadImageHTML(from urls: [URL]) -> String {
        guard let lead = urls.first else { return "" }
        let escaped = lead.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<img src=\"\(escaped)\">\n"
    }

    private static func escapeHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
