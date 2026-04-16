import Foundation
import UIKit

/// Extracts web page content from Share Extension input items.
/// Handles URLs, HTML text, plain text, and images shared from Safari and other apps.
enum WebContentExtractor {

    struct RawContent {
        let title: String
        let url: URL?
        let html: String?
        let plainText: String?
        /// Images shared directly (e.g. from Photos, Screenshots). Not from HTML extraction.
        let sharedImages: [Data]
    }

    /// Extract content from the NSExtensionContext input items.
    static func extract(from extensionContext: NSExtensionContext) async -> RawContent? {
        guard let items = extensionContext.inputItems as? [NSExtensionItem] else {
            return nil
        }

        var url: URL?
        var html: String?
        var plainText: String?
        var title: String?
        var sharedImages: [Data] = []

        for item in items {
            // Grab the attributed title if available
            if let attrTitle = item.attributedContentText?.string, !attrTitle.isEmpty {
                title = attrTitle
            }

            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // 1. Try to get a URL (highest priority — Safari shares the page URL)
                if provider.hasItemConformingToTypeIdentifier("public.url") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.url") as? URL {
                        url = loaded
                    }
                }

                // 2. Try to get HTML content directly
                if provider.hasItemConformingToTypeIdentifier("public.html") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.html") as? String {
                        html = loaded
                    }
                }

                // 3. Try plain text as fallback
                if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: "public.plain-text") as? String {
                        plainText = loaded
                    }
                }

                // 4. Property list (Safari sometimes sends data this way)
                if provider.hasItemConformingToTypeIdentifier("public.property-list") {
                    if let dict = try? await provider.loadItem(forTypeIdentifier: "public.property-list") as? [String: Any] {
                        if let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                            if let pageTitle = results["title"] as? String {
                                title = pageTitle
                            }
                            if let pageURL = results["URL"] as? String {
                                url = URL(string: pageURL)
                            }
                            if let pageHTML = results["html"] as? String {
                                html = pageHTML
                            }
                        }
                    }
                }

                // 5. Try to get images shared directly (Photos, Screenshots, etc.)
                if provider.hasItemConformingToTypeIdentifier("public.image") {
                    if let imageData = try? await loadImageData(from: provider) {
                        sharedImages.append(imageData)
                    }
                }
            }
        }

        // If plain text looks like a URL and we don't already have one, treat it as a URL
        if url == nil, let text = plainText {
            if let detected = detectURL(in: text) {
                url = detected
            }
        }

        // If we have a URL but no HTML, fetch the page content
        if html == nil, let pageURL = url {
            html = await fetchHTML(from: pageURL)
        }

        // Derive title from HTML <title> tag if not already set
        if title == nil || title!.isEmpty {
            if let h = html {
                title = extractTitle(from: h)
            }
        }

        // Final fallback for title
        if title == nil || title!.isEmpty {
            if !sharedImages.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm"
                title = "Clipped Image \u{2014} \(formatter.string(from: Date()))"
            } else {
                title = url?.host ?? "Untitled"
            }
        }

        return RawContent(
            title: title!,
            url: url,
            html: html,
            plainText: plainText,
            sharedImages: sharedImages
        )
    }

    /// Detect a URL in plain text. Many apps (Twitter, Reddit, Messages) share URLs as plain text.
    private static func detectURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quick check: if the entire text is a URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if let url = URL(string: trimmed), url.host != nil {
                return url
            }
        }
        // Try to find a URL anywhere in the text using NSDataDetector
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = detector.firstMatch(in: trimmed, range: range),
           let url = match.url,
           let scheme = url.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            return url
        }
        return nil
    }

    /// Load image data from an NSItemProvider. Handles UIImage, Data, and URL payloads.
    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        // Try loading as Data first
        if let data = try? await provider.loadItem(forTypeIdentifier: "public.image") {
            if let imageData = data as? Data {
                return imageData
            }
            if let image = data as? UIImage, let pngData = image.pngData() {
                return pngData
            }
            if let imageURL = data as? URL, let imageData = try? Data(contentsOf: imageURL) {
                return imageData
            }
        }
        return nil
    }

    /// Fetch HTML from a URL, detecting character encoding from the Content-Type header.
    private static func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let encoding = Self.detectEncoding(from: httpResponse)
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8)
    }

    /// Detect string encoding from HTTP Content-Type header charset.
    private static func detectEncoding(from response: HTTPURLResponse) -> String.Encoding {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else {
            return .utf8
        }

        let lower = contentType.lowercased()

        // Extract charset value from Content-Type header
        if let charsetRange = lower.range(of: "charset=") {
            let charsetStart = charsetRange.upperBound
            var charsetValue = String(lower[charsetStart...])
            // Strip any trailing parameters
            if let semicolonIndex = charsetValue.firstIndex(of: ";") {
                charsetValue = String(charsetValue[..<semicolonIndex])
            }
            charsetValue = charsetValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            switch charsetValue {
            case "utf-8":
                return .utf8
            case "iso-8859-1", "latin1", "latin-1":
                return .isoLatin1
            case "windows-1252", "cp1252":
                return .windowsCP1252
            case "ascii", "us-ascii":
                return .ascii
            case "iso-8859-2", "latin2", "latin-2":
                return .isoLatin2
            case "utf-16":
                return .utf16
            default:
                return .utf8
            }
        }

        return .utf8
    }

    /// Extract the <title> content from HTML.
    private static func extractTitle(from html: String) -> String? {
        let pattern = #"<title[^>]*>(.*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[range])
        // Decode basic HTML entities
        return raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
