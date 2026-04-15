import Foundation
import UIKit

/// Represents a single extracted image from the web page.
struct ExtractedImage: Sendable {
    /// The original URL of the image.
    let sourceURL: URL
    /// The downloaded image data.
    let data: Data
    /// A sanitized filename (e.g. "image-1.png").
    let filename: String
    /// OCR-recognized text, if any.
    var ocrText: String?
}

/// The result of clipping a web page.
struct ClipResult {
    /// The page title.
    let title: String
    /// The original page URL.
    let sourceURL: URL?
    /// The article body converted to Markdown.
    let markdownBody: String
    /// Extracted images.
    let images: [ExtractedImage]
    /// The date the clip was created.
    let clippedDate: Date

    /// Assemble the final Markdown file content, including optional YAML frontmatter.
    /// `imageReferences` maps source URL strings to local relative paths (e.g. "images/abc-1.png").
    func toMarkdown(includeFrontmatter: Bool, imageReferences: [String: String] = [:]) -> String {
        var parts: [String] = []

        if includeFrontmatter {
            var fm = "---\n"
            fm += "title: \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
            if let url = sourceURL {
                fm += "source: \"\(url.absoluteString)\"\n"
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            fm += "clipped: \(formatter.string(from: clippedDate))\n"
            fm += "type: article\n"
            fm += "---\n"
            parts.append(fm)
        }

        parts.append("# \(title)\n")

        if let url = sourceURL {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateStr = dateFormatter.string(from: clippedDate)
            parts.append("> [Source](\(url.absoluteString)) — Clipped \(dateStr)\n")
        }

        parts.append(markdownBody)

        // Append image references as properly formatted Markdown images
        if !imageReferences.isEmpty {
            parts.append("\n## Images\n")
            for (index, image) in images.enumerated() {
                if let localPath = imageReferences[image.sourceURL.absoluteString] {
                    parts.append("![image-\(index + 1)](\(localPath))\n")
                }
            }
        }

        // Append OCR text blocks for images that had recognized text
        let ocrImages = images.filter { $0.ocrText != nil && !$0.ocrText!.isEmpty }
        if !ocrImages.isEmpty {
            parts.append("\n---\n")
            parts.append("## Extracted Text (OCR)\n")
            for img in ocrImages {
                parts.append("### \(img.filename)\n")
                parts.append("> \(img.ocrText!.replacingOccurrences(of: "\n", with: "\n> "))\n")
            }
        }

        return parts.joined(separator: "\n")
    }
}
