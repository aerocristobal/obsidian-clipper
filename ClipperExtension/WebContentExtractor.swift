import Foundation
import UIKit

/// Extracts web page content from Share Extension input items.
/// Handles URLs, HTML text, plain text, and images shared from Safari and other apps.
enum WebContentExtractor {

    /// URLSession configured with timeouts matching ImageProcessor for consistency.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

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
                    if let imageData = await loadImageData(from: provider) {
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
    static func detectURL(in text: String) -> URL? {
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

    /// Fetch HTML from a URL, detecting character encoding from the Content-Type header or HTML meta tags.
    /// Rejects non-HTTP(S) schemes (file://, javascript:, ftp://, data:, etc.).
    private static func fetchHTML(from url: URL) async -> String? {
        guard isAllowedScheme(url) else {
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let encoding = Self.detectEncoding(response: httpResponse, body: data)
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8)
    }

    /// Returns true if the URL uses a scheme safe for network fetching (http/https only).
    static func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Detect string encoding from HTTP Content-Type header charset.
    /// Retained for backward compatibility; delegates to the body-aware variant with an empty body.
    static func detectEncoding(from response: HTTPURLResponse) -> String.Encoding {
        return detectEncoding(response: response, body: Data())
    }

    /// Detect string encoding, preferring HTTP Content-Type charset, then HTML `<meta>` tags in the body.
    static func detectEncoding(response: HTTPURLResponse, body: Data) -> String.Encoding {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let charset = parseCharset(fromContentType: contentType) {
            return encoding(forCharset: charset)
        }

        if let metaCharset = parseCharset(fromHTMLBody: body) {
            return encoding(forCharset: metaCharset)
        }

        return .utf8
    }

    /// Parse the charset value from an HTTP Content-Type header value.
    private static func parseCharset(fromContentType contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let charsetRange = lower.range(of: "charset=") else {
            return nil
        }
        var charsetValue = String(lower[charsetRange.upperBound...])
        if let semicolonIndex = charsetValue.firstIndex(of: ";") {
            charsetValue = String(charsetValue[..<semicolonIndex])
        }
        charsetValue = charsetValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return charsetValue.isEmpty ? nil : charsetValue
    }

    /// Parse the charset from the first ~1KB of an HTML document, looking at `<meta>` tags.
    /// Supports both `<meta http-equiv="Content-Type" content="...; charset=...">` and `<meta charset="...">`.
    private static func parseCharset(fromHTMLBody body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        let prefix = body.prefix(1024)
        guard let head = String(data: prefix, encoding: .ascii)
                ?? String(data: prefix, encoding: .isoLatin1) else {
            return nil
        }

        let pattern = #"<meta[^>]+charset\s*=\s*["']?([^"'>\s;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(head.startIndex..., in: head)
        guard let match = regex.firstMatch(in: head, range: range),
              match.numberOfRanges > 1,
              let charsetRange = Range(match.range(at: 1), in: head) else {
            return nil
        }
        return String(head[charsetRange]).lowercased()
    }

    /// Map a charset string (lowercased) to a `String.Encoding`, falling back to UTF-8 for unknown values.
    private static func encoding(forCharset charset: String) -> String.Encoding {
        switch charset {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "iso-8859-2", "latin2", "latin-2":
            return .isoLatin2
        case "iso-8859-15", "latin-9", "latin9":
            return isoLatin15Encoding()
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "windows-1251", "cp1251":
            return .windowsCP1251
        case "ascii", "us-ascii":
            return .ascii
        case "utf-16":
            return .utf16
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        case "euc-jp", "eucjp":
            return .japaneseEUC
        default:
            return .utf8
        }
    }

    /// ISO-8859-15 (Latin-9) via CoreFoundation bridging; falls back to UTF-8 if unavailable.
    private static func isoLatin15Encoding() -> String.Encoding {
        let cfEncoding = CFStringEncoding(CFStringEncodings.isoLatin9.rawValue)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        if nsEncoding == UInt(kCFStringEncodingInvalidId) { return .utf8 }
        return String.Encoding(rawValue: nsEncoding)
    }

    /// Extract the <title> content from HTML.
    static func extractTitle(from html: String) -> String? {
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
