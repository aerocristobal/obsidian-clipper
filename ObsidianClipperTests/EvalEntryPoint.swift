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
    /// injection; plain-text bodies are wrapped in `<p>` per paragraph
    /// (split on `\n\n`, then `\n` if no double newline) and pushed through
    /// the same converter so output style is consistent across branches.
    private static func renderJSONLDBody(
        _ ld: JSONLDExtractor.Result,
        baseURL: URL?
    ) -> (markdown: String, imageCount: Int) {
        let bodyHTML: String
        if ld.articleBodyIsHTML {
            bodyHTML = ld.articleBody
        } else {
            bodyHTML = wrapPlainTextAsHTML(ld.articleBody)
        }

        // Inject image markers on the body HTML (article-only — no recirc
        // bleed-through).
        let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(bodyHTML, baseURL: baseURL)
        let markdown = HTMLToMarkdown.convert(markerResult.html)
        let surviving = HTMLToMarkdown.findMarkerIndices(in: markdown)
        return (markdown, surviving.count)
    }

    private static func wrapPlainTextAsHTML(_ text: String) -> String {
        // Prefer paragraph splits on `\n\n`. If the body has no blank
        // lines, fall back to single `\n` (still common — Wired emits a
        // single `\n` between paragraphs).
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let separator = normalized.contains("\n\n") ? "\n\n" : "\n"
        let paragraphs = normalized
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.map { "<p>\(escapeHTML($0))</p>" }.joined(separator: "\n")
    }

    /// Minimal HTML-escape for plain-text bodies. Only escapes `<` and `&`
    /// so the markdown converter sees them as text, not tags.
    private static func escapeHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
