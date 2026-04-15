import Foundation
import UIKit

/// Converts HTML content to Markdown using Apple's native NSAttributedString
/// HTML importer, then walking the attributed string to emit Markdown syntax.
enum HTMLToMarkdown {

    /// Main entry point: takes raw HTML and returns Markdown text.
    /// Must run on the main actor — Apple's `NSAttributedString` HTML importer
    /// instantiates WebKit/UIFont on the main thread.
    @MainActor
    static func convert(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return stripHTMLTags(html)
        }

        return attributedStringToMarkdown(attributed)
    }

    /// Walk the attributed string and emit Markdown.
    private static func attributedStringToMarkdown(_ attrStr: NSAttributedString) -> String {
        var md = ""
        let full = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let text = (attrStr.string as NSString).substring(with: range)

            // Skip empty runs
            guard !text.isEmpty else { return }

            var prefix = ""
            var suffix = ""

            // Bold
            if let font = attrs[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) && traits.contains(.traitItalic) {
                    prefix += "***"
                    suffix = "***" + suffix
                } else if traits.contains(.traitBold) {
                    prefix += "**"
                    suffix = "**" + suffix
                } else if traits.contains(.traitItalic) {
                    prefix += "_"
                    suffix = "_" + suffix
                }

                // Heading detection: font size > 20pt heuristic
                let size = font.pointSize
                if size >= 28 {
                    prefix = "## " + prefix
                } else if size >= 22 {
                    prefix = "### " + prefix
                }
            }

            // Links
            if let link = attrs[.link] {
                let urlStr: String
                if let url = link as? URL {
                    urlStr = url.absoluteString
                } else {
                    urlStr = "\(link)"
                }
                prefix = "[\(prefix)"
                suffix = "\(suffix)](\(urlStr))"
            }

            // Strikethrough
            if let strikethrough = attrs[.strikethroughStyle] as? Int, strikethrough != 0 {
                prefix = "~~" + prefix
                suffix = suffix + "~~"
            }

            md += prefix + text + suffix
        }

        // Clean up: normalize whitespace, fix double newlines
        md = md.replacingOccurrences(of: "\r\n", with: "\n")
        md = md.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return md.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback: strip HTML tags with regex if NSAttributedString parsing fails.
    private static func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Image URL extraction from raw HTML

    /// Extract all image source URLs from HTML.
    static func extractImageURLs(from html: String, baseURL: URL?) -> [URL] {
        let pattern = #"<img[^>]+src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        return matches.compactMap { match -> URL? in
            guard match.numberOfRanges > 1 else { return nil }
            let srcRange = match.range(at: 1)
            let src = nsHTML.substring(with: srcRange)

            if let absolute = URL(string: src), absolute.scheme != nil {
                return absolute
            } else if let base = baseURL {
                return URL(string: src, relativeTo: base)
            }
            return nil
        }
    }
}
