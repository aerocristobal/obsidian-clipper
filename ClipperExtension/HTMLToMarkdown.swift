import Foundation
import UIKit

/// Converts HTML content to Markdown using Apple's native NSAttributedString
/// HTML importer, then walking the attributed string to emit Markdown syntax.
enum HTMLToMarkdown {

    /// Maximum HTML size (in bytes) to parse. Prevents memory exhaustion
    /// in the share extension's constrained environment.
    static let maxHTMLSize = 2 * 1024 * 1024 // 2 MB

    /// Main entry point: takes raw HTML and returns Markdown text.
    /// Must run on the main actor — Apple's `NSAttributedString` HTML importer
    /// instantiates WebKit/UIFont on the main thread.
    @MainActor
    static func convert(_ html: String) -> String {
        var htmlToConvert = html

        // Truncate oversized HTML to prevent memory exhaustion
        if let data = html.data(using: .utf8), data.count > maxHTMLSize {
            let truncated = data.prefix(maxHTMLSize)
            htmlToConvert = String(data: truncated, encoding: .utf8) ?? html
        }

        guard let data = htmlToConvert.data(using: .utf8) else { return htmlToConvert }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return stripHTMLTags(htmlToConvert)
        }

        return attributedStringToMarkdown(attributed)
    }

    // MARK: - Monospace font detection

    private static let monospaceFamilies: Set<String> = [
        "courier", "courier new", "menlo", "monaco", "consolas",
        "sf mono", "sfmono", "andale mono", "dejavu sans mono",
        "liberation mono", "ubuntu mono", "source code pro"
    ]

    private static func isMonospaceFont(_ font: UIFont) -> Bool {
        let family = font.familyName.lowercased()
        if monospaceFamilies.contains(family) { return true }
        // Also check if the font descriptor has the monospace trait
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
    }

    // MARK: - Heading detection

    private static func headingLevel(for font: UIFont) -> Int? {
        // Try NSParagraphStyle headerLevel if available via font descriptor
        // Fall back to font-size heuristic with granular tiers
        let size = font.pointSize
        if size >= 32 { return 1 }
        if size >= 26 { return 2 }
        if size >= 22 { return 3 }
        if size >= 18 { return 4 }
        return nil
    }

    // MARK: - Attributed String to Markdown

    private static func attributedStringToMarkdown(_ attrStr: NSAttributedString) -> String {
        var md = ""
        let full = NSRange(location: 0, length: attrStr.length)

        // Track state for multi-line constructs
        var inCodeBlock = false
        var lastLineWasBlank = false

        attrStr.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let text = (attrStr.string as NSString).substring(with: range)

            // Skip empty runs
            guard !text.isEmpty else { return }

            let font = attrs[.font] as? UIFont
            let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle

            // Detect monospace (code)
            let isMono = font.map { isMonospaceFont($0) } ?? false

            // Detect heading
            let heading = font.flatMap { headingLevel(for: $0) }
            let isHeading = heading != nil

            // Detect list context from NSTextList
            let textLists = paragraphStyle?.textLists ?? []
            let isListItem = !textLists.isEmpty

            // Detect blockquote via headIndent heuristic
            // (paragraphs with significant indentation that aren't list items)
            let headIndent = paragraphStyle?.headIndent ?? 0
            let isBlockquote = !isListItem && !isHeading && headIndent >= 30

            // Process text line by line for block-level elements
            let lines = text.components(separatedBy: "\n")

            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Handle blank lines
                if trimmed.isEmpty {
                    if lineIndex > 0 || text.hasPrefix("\n") {
                        if inCodeBlock {
                            md += "\n"
                        } else if !lastLineWasBlank {
                            md += "\n\n"
                            lastLineWasBlank = true
                        }
                    }
                    continue
                }

                lastLineWasBlank = false

                // Close code block if we exit monospace
                if inCodeBlock && !isMono {
                    md += "```\n\n"
                    inCodeBlock = false
                }

                var linePrefix = ""
                var lineSuffix = ""

                // Code block detection (multi-line monospace)
                if isMono && !isHeading {
                    if !inCodeBlock {
                        // Check if this looks like a code block (multiple lines) or inline code
                        let totalMonoLines = text.components(separatedBy: "\n").filter {
                            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                        }.count

                        if totalMonoLines > 1 || text.contains("\n") {
                            md += "```\n"
                            inCodeBlock = true
                        }
                    }

                    if inCodeBlock {
                        md += trimmed + "\n"
                        continue
                    } else {
                        // Inline code
                        linePrefix = "`"
                        lineSuffix = "`"
                    }
                }

                // Heading
                if let level = heading {
                    let hashes = String(repeating: "#", count: level)
                    // Don't add bold markers inside headings
                    md += "\(hashes) \(trimmed)\n\n"
                    continue
                }

                // List item detection: strip the auto-inserted bullet/number prefix
                if isListItem, let list = textLists.last {
                    let markerFormat = list.markerFormat
                    var cleanLine = trimmed

                    // Strip the system-inserted list marker (e.g. "1.\t", "•\t")
                    // NSAttributedString inserts markers like "1.\t", "•\t", etc.
                    let patterns = [
                        #"^\d+[\.\)]\s*"#,     // "1. " or "1) "
                        #"^[•·‣⁃◦]\s*"#,       // bullet chars
                        #"^[-*]\s*"#,           // markdown-style bullets
                        #"^\{[^}]*\}\s*"#       // {format} markers from NSTextList
                    ]
                    for pattern in patterns {
                        if let regex = try? NSRegularExpression(pattern: pattern),
                           let match = regex.firstMatch(in: cleanLine, range: NSRange(cleanLine.startIndex..., in: cleanLine)) {
                            cleanLine = String(cleanLine[Range(match.range, in: cleanLine)!.upperBound...])
                            break
                        }
                    }

                    if markerFormat == .decimal || markerFormat == .lowercaseAlpha || markerFormat == .uppercaseAlpha {
                        linePrefix = "1. "
                    } else {
                        linePrefix = "- "
                    }

                    // Apply inline formatting to the clean line
                    let formatted = applyInlineFormatting(cleanLine, font: font, attrs: attrs)
                    md += linePrefix + formatted + "\n"
                    continue
                }

                // Blockquote
                if isBlockquote {
                    let formatted = applyInlineFormatting(trimmed, font: font, attrs: attrs)
                    md += "> " + formatted + "\n"
                    continue
                }

                // Regular text with inline formatting
                let formatted = linePrefix + applyInlineFormatting(trimmed, font: font, attrs: attrs) + lineSuffix
                md += formatted

                // Add appropriate line ending
                if lineIndex < lines.count - 1 {
                    md += "\n"
                }
            }
        }

        // Close any open code block
        if inCodeBlock {
            md += "```\n"
        }

        // Clean up: normalize whitespace, fix excessive newlines
        md = md.replacingOccurrences(of: "\r\n", with: "\n")
        md = md.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // Detect tab-separated content that may be from tables and attempt conversion
        md = attemptTableConversion(md)

        return md.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apply inline formatting (bold, italic, strikethrough, links) to a text fragment.
    private static func applyInlineFormatting(_ text: String, font: UIFont?, attrs: [NSAttributedString.Key: Any]) -> String {
        var prefix = ""
        var suffix = ""

        if let font = font {
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

        return prefix + text + suffix
    }

    // MARK: - Table Detection

    /// Attempt to detect tab-separated content that may have come from HTML tables
    /// and convert it to Markdown table format.
    private static func attemptTableConversion(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var tableLines: [String] = []

        for line in lines {
            if line.contains("\t") {
                tableLines.append(line)
            } else {
                if tableLines.count >= 2 {
                    result.append(contentsOf: convertToTable(tableLines))
                } else {
                    result.append(contentsOf: tableLines)
                }
                tableLines.removeAll()
                result.append(line)
            }
        }

        // Handle trailing table lines
        if tableLines.count >= 2 {
            result.append(contentsOf: convertToTable(tableLines))
        } else {
            result.append(contentsOf: tableLines)
        }

        return result.joined(separator: "\n")
    }

    private static func convertToTable(_ lines: [String]) -> [String] {
        let rows = lines.map { $0.components(separatedBy: "\t") }
        guard let columnCount = rows.first?.count, columnCount > 1 else {
            return lines
        }

        // Ensure all rows have the same column count
        let normalizedRows = rows.map { row -> [String] in
            var r = row
            while r.count < columnCount { r.append("") }
            return Array(r.prefix(columnCount))
        }

        var tableOutput: [String] = []

        // Header row
        tableOutput.append("| " + normalizedRows[0].joined(separator: " | ") + " |")
        // Separator
        tableOutput.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        // Data rows
        for row in normalizedRows.dropFirst() {
            tableOutput.append("| " + row.joined(separator: " | ") + " |")
        }

        return tableOutput
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
