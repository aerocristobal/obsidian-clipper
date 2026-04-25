import Foundation

/// Fast-path article extractor that pulls structured article data from
/// `<script type="application/ld+json">` blocks (Schema.org Article /
/// NewsArticle / BlogPosting). Many news sites embed the full article body
/// as `articleBody` — when present, this is exactly what the publisher
/// considers their canonical article, so we can short-circuit the
/// Readability heuristic.
///
/// Returns `nil` when:
///   - no JSON-LD blocks are present
///   - no Article-typed entry is found
///   - `articleBody` is missing or shorter than `minBodyChars`
///
/// Callers should fall through to Readability when nil is returned.
enum JSONLDExtractor {

    struct Result {
        let title: String
        /// Either an HTML fragment (if the publisher embedded HTML) or
        /// plain text. Use `articleBodyIsHTML` to disambiguate.
        let articleBody: String
        let articleBodyIsHTML: Bool
        let excerpt: String?
        let siteName: String?
        let byline: String?
    }

    /// JSON-LD `@type` values we accept as article-bearing.
    private static let articleTypes: Set<String> = [
        "Article",
        "NewsArticle",
        "BlogPosting",
        "ReportageNewsArticle",
        "Report",
        "LiveBlogPosting"
    ]

    /// Try to extract an article body from JSON-LD. Returns nil when no
    /// substantial body is found.
    static func tryFastPath(html: String, minBodyChars: Int = 500) -> Result? {
        let blocks = extractLDBlocks(from: html)
        if blocks.isEmpty { return nil }

        var best: [String: Any]? = nil
        var bestBodyLen = 0

        for block in blocks {
            // Some sites HTML-escape entities inside the script tag
            // (e.g. `&quot;`). JSON parses fine without unescaping in
            // practice, because publishers we've seen emit raw JSON; if
            // parsing fails we just skip the block.
            guard let data = block.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }

            for candidate in walkForArticles(parsed) {
                let bodyLen = (candidate["articleBody"] as? String)?.count ?? 0
                if bodyLen > bestBodyLen {
                    best = candidate
                    bestBodyLen = bodyLen
                }
            }
        }

        guard let article = best,
              let body = article["articleBody"] as? String,
              body.count >= minBodyChars
        else { return nil }

        let title = (article["headline"] as? String) ?? ""
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHTML = looksLikeHTML(trimmed)
        let excerpt = article["description"] as? String
        let byline = bylineFrom(article)
        let siteName = siteNameFrom(article)

        return Result(
            title: decodeEntities(title),
            articleBody: trimmed,
            articleBodyIsHTML: isHTML,
            excerpt: excerpt.map(decodeEntities),
            siteName: siteName.map(decodeEntities),
            byline: byline.map(decodeEntities)
        )
    }

    // MARK: - Block extraction

    /// Regex for `<script ... type="application/ld+json" ...>...</script>`,
    /// allowing any attribute order and quoted/unquoted type values.
    private static let scriptRegex: NSRegularExpression = {
        // Pattern intentionally permissive on whitespace and attribute order.
        // Matches:
        //   <script type="application/ld+json">...
        //   <script type='application/ld+json'>...
        //   <script type=application/ld+json>...
        //   <script id="..." type="application/ld+json">...
        let pattern = #"<script\b[^>]*?type\s*=\s*["']?application/ld\+json["']?[^>]*>([\s\S]*?)</script\s*>"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func extractLDBlocks(from html: String) -> [String] {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = scriptRegex.matches(in: html, options: [], range: range)
        var blocks: [String] = []
        for m in matches where m.numberOfRanges >= 2 {
            if let r = Range(m.range(at: 1), in: html) {
                let raw = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { blocks.append(raw) }
            }
        }
        return blocks
    }

    // MARK: - Walk for Article-typed entries

    /// Recursively walks a parsed JSON-LD object/array, yielding any object
    /// whose `@type` matches an article type. Handles `@graph` wrappers and
    /// array-valued `@type`.
    private static func walkForArticles(_ obj: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let arr = obj as? [Any] {
            for x in arr { out.append(contentsOf: walkForArticles(x)) }
            return out
        }
        guard let dict = obj as? [String: Any] else { return out }

        if matchesArticleType(dict["@type"]) {
            out.append(dict)
        }
        if let graph = dict["@graph"] {
            out.append(contentsOf: walkForArticles(graph))
        }
        return out
    }

    private static func matchesArticleType(_ value: Any?) -> Bool {
        if let s = value as? String {
            return articleTypes.contains(s)
        }
        if let arr = value as? [String] {
            return arr.contains(where: articleTypes.contains)
        }
        return false
    }

    // MARK: - Helpers

    /// Heuristic: does the body look like HTML? Check the first ~120 chars
    /// for an angle bracket followed by a letter (i.e. a tag start). Plain
    /// text bodies sometimes contain `<` in prose, so we look specifically
    /// for tag-shaped openings.
    private static func looksLikeHTML(_ s: String) -> Bool {
        let head = s.prefix(200)
        // Match `<` followed by a letter or `/` — a real tag opener.
        return head.range(of: "<[a-zA-Z/]", options: .regularExpression) != nil
    }

    private static func bylineFrom(_ article: [String: Any]) -> String? {
        guard let author = article["author"] else { return nil }
        if let s = author as? String { return s }
        if let dict = author as? [String: Any], let n = dict["name"] as? String { return n }
        if let arr = author as? [Any] {
            let names: [String] = arr.compactMap {
                if let s = $0 as? String { return s }
                if let d = $0 as? [String: Any], let n = d["name"] as? String { return n }
                return nil
            }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return nil
    }

    private static func siteNameFrom(_ article: [String: Any]) -> String? {
        if let pub = article["publisher"] as? [String: Any], let n = pub["name"] as? String {
            return n
        }
        return nil
    }

    /// Minimal HTML-entity decoder for the few common entities that show up
    /// in titles/headlines (`&amp;`, `&#8217;`, `&quot;`, etc.). Body content
    /// is handled by the markdown converter when HTML; plain-text bodies
    /// from the publishers we've inspected are already decoded.
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities: &#NNNN; or &#xHHHH;
        result = decodeNumericEntities(result)
        return result
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        let pattern = "&#([xX]?)([0-9A-Fa-f]+);"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let hexFlag = ns.substring(with: m.range(at: 1))
            let digits = ns.substring(with: m.range(at: 2))
            let radix = hexFlag.isEmpty ? 10 : 16
            if let scalar = UInt32(digits, radix: radix), let u = Unicode.Scalar(scalar) {
                out += String(Character(u))
            }
            cursor = full.location + full.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
