import Foundation

// MARK: - Result Type

/// The result of Readability extraction, containing the cleaned article content
/// and metadata extracted from the page.
struct ReadabilityResult: Sendable {
    let articleHTML: String
    let title: String?
    let excerpt: String?
    let siteName: String?
}

// MARK: - Readability Extractor

/// A Mozilla Readability-inspired article extractor that isolates the main content
/// from a web page's HTML by scoring block-level elements and selecting the most
/// likely article container.
///
/// Implemented in pure Swift with no external dependencies. The HTML parser is a
/// minimal recursive-descent parser — not spec-compliant, but robust enough for
/// real-world pages.
enum ReadabilityExtractor {

    /// Extract the main article content from raw HTML.
    /// - Parameters:
    ///   - html: The full raw HTML of the page.
    ///   - url: The page URL (used for resolving relative links if needed).
    /// - Returns: A `ReadabilityResult` with the cleaned article HTML, or `nil`
    ///   if extraction fails.
    static func extract(html: String, url: URL?) -> ReadabilityResult? {
        var parser = HTMLParser(html: html)
        guard let document = parser.parse() else { return nil }

        // Extract metadata before preprocessing mutates the tree
        let metadata = extractMetadata(from: document)

        // Preprocess: remove junk elements
        preprocess(&document.children)

        // Score candidates
        var candidates: [CandidateScore] = []
        scoreCandidates(node: document, candidates: &candidates)

        guard let winner = candidates.max(by: { $0.score < $1.score }),
              winner.score > 0 else {
            return nil
        }

        // Post-process: clean up the winning subtree
        postProcess(winner.element)

        // Serialize the winner back to HTML
        let articleHTML = winner.element.serialize()

        // Extract title: prefer og:title, then <h1> within article, then <title> tag
        let title = metadata.ogTitle
            ?? findFirstHeading(in: winner.element)
            ?? metadata.title

        // Extract excerpt: first paragraph text or meta description
        let excerpt = metadata.description
            ?? findFirstParagraphText(in: winner.element)

        return ReadabilityResult(
            articleHTML: articleHTML,
            title: title,
            excerpt: excerpt,
            siteName: metadata.siteName
        )
    }
}

// MARK: - Lightweight DOM

/// A node in the parsed HTML tree. Uses a class (reference type) so that parent
/// pointers and in-place mutation during scoring work naturally. The tree is built
/// once and discarded after extraction, so ARC overhead is minimal.
final class HTMLNode {
    enum Kind {
        case element(tag: String, attributes: [(name: String, value: String)])
        case text(String)
    }

    var kind: Kind
    var children: [HTMLNode]
    weak var parent: HTMLNode?

    init(kind: Kind, children: [HTMLNode] = []) {
        self.kind = kind
        self.children = children
    }

    var tag: String? {
        if case .element(let tag, _) = kind { return tag }
        return nil
    }

    var attributes: [(name: String, value: String)] {
        if case .element(_, let attrs) = kind { return attrs }
        return []
    }

    func attribute(_ name: String) -> String? {
        attributes.first(where: { $0.name.lowercased() == name.lowercased() })?.value
    }

    /// Concatenated text content of this node and all descendants.
    var textContent: String {
        switch kind {
        case .text(let t): return t
        case .element: return children.map(\.textContent).joined()
        }
    }

    /// Serialize this node (and descendants) back to an HTML string.
    func serialize() -> String {
        switch kind {
        case .text(let t):
            return t
        case .element(let tag, let attrs):
            let attrStr = attrs.map { " \($0.name)=\"\(escapeAttribute($0.value))\"" }.joined()
            let inner = children.map { $0.serialize() }.joined()
            if HTMLParser.selfClosingTags.contains(tag) {
                return "<\(tag)\(attrStr) />"
            }
            return "<\(tag)\(attrStr)>\(inner)</\(tag)>"
        }
    }
}

private func escapeAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - HTML Parser

/// Minimal recursive-descent HTML parser. Produces an `HTMLNode` tree.
/// Not spec-compliant — handles the common patterns found on real web pages.
struct HTMLParser {

    static let selfClosingTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Tags whose content is raw text (not parsed as HTML).
    private static let rawTextTags: Set<String> = [
        "script", "style", "textarea", "title", "noscript"
    ]

    /// Tags that implicitly close certain open tags.
    private static let implicitCloseRules: [String: Set<String>] = [
        "p": ["p", "div", "section", "article", "aside", "nav", "header",
              "footer", "ul", "ol", "table", "blockquote", "form", "h1",
              "h2", "h3", "h4", "h5", "h6", "pre", "hr"],
        "li": ["li"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "tr": ["tr"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "option": ["option"],
    ]

    private let html: String
    private var index: String.Index
    private let endIndex: String.Index

    init(html: String) {
        self.html = html
        self.index = html.startIndex
        self.endIndex = html.endIndex
    }

    mutating func parse() -> HTMLNode? {
        let children = parseNodes(until: nil)
        let root = HTMLNode(kind: .element(tag: "document", attributes: []), children: children)
        setParents(root)
        return root
    }

    // MARK: - Core Parsing

    private mutating func parseNodes(until closingTag: String?) -> [HTMLNode] {
        var nodes: [HTMLNode] = []
        while index < endIndex {
            // Check for closing tag
            if let closing = closingTag, peekClosingTag(closing) {
                break
            }

            if peek() == "<" {
                if peekString("<!--") {
                    skipComment()
                } else if peekString("<![CDATA[") {
                    skipCDATA()
                } else if peekString("<!") || peekString("<?") {
                    skipDeclaration()
                } else if peekString("</") {
                    // Unexpected closing tag — if we're in an implicit-close context,
                    // let the caller handle it; otherwise skip it.
                    if closingTag != nil {
                        break
                    }
                    skipToAfter(">")
                } else {
                    if let element = parseElement(parentClosingTag: closingTag) {
                        nodes.append(element)
                    }
                }
            } else {
                let text = parseText()
                if !text.isEmpty {
                    nodes.append(HTMLNode(kind: .text(text)))
                }
            }
        }
        return nodes
    }

    private mutating func parseElement(parentClosingTag: String?) -> HTMLNode? {
        guard consume("<") else { return nil }

        let tag = parseTagName().lowercased()
        guard !tag.isEmpty else {
            // Malformed tag — skip to >
            skipToAfter(">")
            return nil
        }

        let attrs = parseAttributes()

        // Check for self-closing /> or self-closing tag
        let selfClose = consume("/")
        consume(">")

        if Self.selfClosingTags.contains(tag) || selfClose {
            return HTMLNode(kind: .element(tag: tag, attributes: attrs))
        }

        // Raw text elements: read until matching closing tag
        if Self.rawTextTags.contains(tag) {
            let content = readUntilClosingTag(tag)
            let textNode = HTMLNode(kind: .text(content))
            return HTMLNode(kind: .element(tag: tag, attributes: attrs), children: [textNode])
        }

        // Parse children
        let children = parseChildren(tag: tag, parentClosingTag: parentClosingTag)
        return HTMLNode(kind: .element(tag: tag, attributes: attrs), children: children)
    }

    private mutating func parseChildren(tag: String, parentClosingTag: String?) -> [HTMLNode] {
        var children: [HTMLNode] = []

        while index < endIndex {
            // Check for our own closing tag
            if peekClosingTag(tag) {
                consumeClosingTag(tag)
                break
            }

            // Check if parent's closing tag terminates us (implicit close)
            if let parent = parentClosingTag, peekClosingTag(parent) {
                break
            }

            // Check for implicit closing rules
            if let openTag = peekOpenTag(),
               let closers = Self.implicitCloseRules[tag],
               closers.contains(openTag) {
                // This opening tag implicitly closes us
                break
            }

            if peek() == "<" {
                if peekString("<!--") {
                    skipComment()
                } else if peekString("<![CDATA[") {
                    skipCDATA()
                } else if peekString("<!") || peekString("<?") {
                    skipDeclaration()
                } else if peekString("</") {
                    // A closing tag that doesn't match us — might be for an ancestor.
                    // Let the ancestor handle it.
                    break
                } else {
                    if let element = parseElement(parentClosingTag: tag) {
                        children.append(element)
                    }
                }
            } else {
                let text = parseText()
                if !text.isEmpty {
                    children.append(HTMLNode(kind: .text(text)))
                }
            }
        }

        return children
    }

    // MARK: - Tag/Attribute Parsing

    private mutating func parseTagName() -> String {
        var name = ""
        while index < endIndex {
            let c = html[index]
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                name.append(c)
                index = html.index(after: index)
            } else {
                break
            }
        }
        return name
    }

    private mutating func parseAttributes() -> [(name: String, value: String)] {
        var attrs: [(name: String, value: String)] = []

        while index < endIndex {
            skipWhitespace()
            guard index < endIndex else { break }

            let c = html[index]
            if c == ">" || c == "/" { break }

            let name = parseAttributeName()
            guard !name.isEmpty else {
                // Skip unknown character
                index = html.index(after: index)
                continue
            }

            skipWhitespace()

            var value = ""
            if index < endIndex && html[index] == "=" {
                index = html.index(after: index)
                skipWhitespace()
                value = parseAttributeValue()
            }

            attrs.append((name: name.lowercased(), value: decodeEntities(value)))
        }

        return attrs
    }

    private mutating func parseAttributeName() -> String {
        var name = ""
        while index < endIndex {
            let c = html[index]
            if c == "=" || c == ">" || c == "/" || c.isWhitespace {
                break
            }
            name.append(c)
            index = html.index(after: index)
        }
        return name
    }

    private mutating func parseAttributeValue() -> String {
        guard index < endIndex else { return "" }

        let quote = html[index]
        if quote == "\"" || quote == "'" {
            index = html.index(after: index)
            var value = ""
            while index < endIndex && html[index] != quote {
                value.append(html[index])
                index = html.index(after: index)
            }
            if index < endIndex { index = html.index(after: index) } // consume closing quote
            return value
        }

        // Unquoted value
        var value = ""
        while index < endIndex {
            let c = html[index]
            if c.isWhitespace || c == ">" || c == "/" { break }
            value.append(c)
            index = html.index(after: index)
        }
        return value
    }

    // MARK: - Text Parsing

    private mutating func parseText() -> String {
        var text = ""
        while index < endIndex && html[index] != "<" {
            text.append(html[index])
            index = html.index(after: index)
        }
        return decodeEntities(text)
    }

    // MARK: - Skip Helpers

    private mutating func skipComment() {
        guard consume("<") else { return }
        guard consume("!") else { return }
        guard consume("-") else { skipToAfter(">"); return }
        guard consume("-") else { skipToAfter(">"); return }

        // Find -->
        while index < endIndex {
            if peekString("-->") {
                index = html.index(index, offsetBy: 3, limitedBy: endIndex) ?? endIndex
                return
            }
            index = html.index(after: index)
        }
    }

    private mutating func skipCDATA() {
        // Skip past ]]>
        while index < endIndex {
            if peekString("]]>") {
                index = html.index(index, offsetBy: 3, limitedBy: endIndex) ?? endIndex
                return
            }
            index = html.index(after: index)
        }
    }

    private mutating func skipDeclaration() {
        skipToAfter(">")
    }

    private mutating func skipToAfter(_ char: Character) {
        while index < endIndex {
            if html[index] == char {
                index = html.index(after: index)
                return
            }
            index = html.index(after: index)
        }
    }

    private mutating func skipWhitespace() {
        while index < endIndex && html[index].isWhitespace {
            index = html.index(after: index)
        }
    }

    // MARK: - Peek / Consume Helpers

    private func peek() -> Character? {
        guard index < endIndex else { return nil }
        return html[index]
    }

    private func peekString(_ s: String) -> Bool {
        guard let end = html.index(index, offsetBy: s.count, limitedBy: endIndex) else {
            return false
        }
        return html[index..<end].lowercased() == s.lowercased()
    }

    @discardableResult
    private mutating func consume(_ char: Character) -> Bool {
        guard index < endIndex && html[index] == char else { return false }
        index = html.index(after: index)
        return true
    }

    @discardableResult
    private mutating func consume(_ s: String) -> Bool {
        guard peekString(s) else { return false }
        index = html.index(index, offsetBy: s.count, limitedBy: endIndex) ?? endIndex
        return true
    }

    private func peekClosingTag(_ tag: String) -> Bool {
        guard peekString("</") else { return false }
        let afterSlash = html.index(index, offsetBy: 2, limitedBy: endIndex) ?? endIndex
        guard afterSlash < endIndex else { return false }

        var i = afterSlash
        // Skip whitespace
        while i < endIndex && html[i].isWhitespace { i = html.index(after: i) }

        var name = ""
        while i < endIndex {
            let c = html[i]
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                name.append(c)
                i = html.index(after: i)
            } else {
                break
            }
        }
        return name.lowercased() == tag.lowercased()
    }

    private mutating func consumeClosingTag(_ tag: String) {
        guard consume("</") else { return }
        skipWhitespace()
        _ = parseTagName()
        skipWhitespace()
        consume(">")
    }

    private func peekOpenTag() -> String? {
        guard index < endIndex, html[index] == "<" else { return nil }
        let next = html.index(after: index)
        guard next < endIndex, html[next] != "/" else { return nil }
        guard html[next].isLetter else { return nil }

        var name = ""
        var i = next
        while i < endIndex {
            let c = html[i]
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" {
                name.append(c)
                i = html.index(after: i)
            } else {
                break
            }
        }
        return name.lowercased()
    }

    private mutating func readUntilClosingTag(_ tag: String) -> String {
        var content = ""
        while index < endIndex {
            if peekClosingTag(tag) {
                consumeClosingTag(tag)
                return content
            }
            content.append(html[index])
            index = html.index(after: index)
        }
        return content
    }

    private func setParents(_ node: HTMLNode) {
        for child in node.children {
            child.parent = node
            setParents(child)
        }
    }
}

// MARK: - HTML Entity Decoding

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }

    var result = ""
    result.reserveCapacity(text.count)
    var i = text.startIndex

    while i < text.endIndex {
        if text[i] == "&" {
            let remaining = text[i...]
            if let semicolonIdx = remaining.firstIndex(of: ";"),
               text.distance(from: i, to: semicolonIdx) <= 10 {
                let entity = String(text[i...semicolonIdx])
                if let decoded = decodeEntity(entity) {
                    result.append(decoded)
                    i = text.index(after: semicolonIdx)
                    continue
                }
            }
        }
        result.append(text[i])
        i = text.index(after: i)
    }
    return result
}

private func decodeEntity(_ entity: String) -> Character? {
    switch entity {
    case "&amp;": return "&"
    case "&lt;": return "<"
    case "&gt;": return ">"
    case "&quot;": return "\""
    case "&apos;": return "'"
    case "&nbsp;": return "\u{00A0}"
    case "&ndash;": return "\u{2013}"
    case "&mdash;": return "\u{2014}"
    case "&lsquo;": return "\u{2018}"
    case "&rsquo;": return "\u{2019}"
    case "&ldquo;": return "\u{201C}"
    case "&rdquo;": return "\u{201D}"
    case "&bull;": return "\u{2022}"
    case "&hellip;": return "\u{2026}"
    case "&copy;": return "\u{00A9}"
    case "&reg;": return "\u{00AE}"
    case "&trade;": return "\u{2122}"
    default:
        // Numeric entities: &#123; or &#x1F;
        if entity.hasPrefix("&#x") || entity.hasPrefix("&#X") {
            let hex = String(entity.dropFirst(3).dropLast())
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                return Character(scalar)
            }
        } else if entity.hasPrefix("&#") {
            let dec = String(entity.dropFirst(2).dropLast())
            if let code = UInt32(dec), let scalar = Unicode.Scalar(code) {
                return Character(scalar)
            }
        }
        return nil
    }
}

// MARK: - Metadata Extraction

private struct PageMetadata {
    var title: String?
    var ogTitle: String?
    var description: String?
    var siteName: String?
}

private extension ReadabilityExtractor {

    static func extractMetadata(from document: HTMLNode) -> PageMetadata {
        var meta = PageMetadata()

        visitNodes(document) { node in
            guard case .element(let tag, _) = node.kind else { return }

            switch tag {
            case "title":
                if meta.title == nil {
                    let raw = node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    meta.title = cleanTitle(raw)
                }
            case "meta":
                let property = node.attribute("property")?.lowercased()
                    ?? node.attribute("name")?.lowercased()
                let content = node.attribute("content")

                switch property {
                case "og:title":
                    meta.ogTitle = content
                case "og:site_name":
                    meta.siteName = content
                case "description", "og:description":
                    if meta.description == nil {
                        meta.description = content
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        return meta
    }

    /// Clean a <title> tag value: strip site name suffixes like " | Site Name" or " - Site Name"
    static func cleanTitle(_ raw: String) -> String {
        let separators: [String] = [" | ", " - ", " – ", " — ", " :: ", " : "]
        for sep in separators {
            let parts = raw.components(separatedBy: sep)
            if parts.count >= 2 {
                // The title is usually the longest segment, or the first one
                let first = parts[0].trimmingCharacters(in: .whitespaces)
                let last = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
                // Use the longer one — the actual title is usually longer than the site name
                if first.count >= last.count && !first.isEmpty {
                    return first
                }
                return last
            }
        }
        return raw
    }

    static func visitNodes(_ node: HTMLNode, _ visitor: (HTMLNode) -> Void) {
        visitor(node)
        for child in node.children {
            visitNodes(child, visitor)
        }
    }
}

// MARK: - Preprocessing

private extension ReadabilityExtractor {

    /// Tags that are always junk and should be removed entirely.
    static let removableTags: Set<String> = [
        "script", "style", "noscript", "nav", "footer", "header",
        "iframe", "object", "embed", "applet", "form"
    ]

    static func preprocess(_ children: inout [HTMLNode]) {
        children.removeAll { node in
            guard case .element(let tag, _) = node.kind else { return false }

            // Remove known junk tags
            if removableTags.contains(tag) { return true }

            // Remove hidden elements
            if isHidden(node) { return true }

            return false
        }

        for child in children {
            if case .element = child.kind {
                preprocess(&child.children)
            }
        }

        // Collapse <br><br> chains into implicit paragraph breaks
        collapseBRChains(&children)
    }

    static func isHidden(_ node: HTMLNode) -> Bool {
        if let style = node.attribute("style")?.lowercased() {
            if style.contains("display:none") || style.contains("display: none") {
                return true
            }
            if style.contains("visibility:hidden") || style.contains("visibility: hidden") {
                return true
            }
        }
        if node.attribute("aria-hidden")?.lowercased() == "true" {
            return true
        }
        if node.attribute("hidden") != nil {
            return true
        }
        return false
    }

    /// Replace sequences of 2+ <br> tags with a paragraph break.
    static func collapseBRChains(_ children: inout [HTMLNode]) {
        var i = 0
        while i < children.count {
            if children[i].tag == "br" {
                // Count consecutive <br> tags (possibly with whitespace-only text nodes between)
                var j = i + 1
                var brCount = 1
                while j < children.count {
                    if children[j].tag == "br" {
                        brCount += 1
                        j += 1
                    } else if case .text(let t) = children[j].kind,
                              t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        j += 1
                    } else {
                        break
                    }
                }
                if brCount >= 2 {
                    // Replace the chain with a double newline text node
                    children.replaceSubrange(i..<j, with: [HTMLNode(kind: .text("\n\n"))])
                }
            }
            i += 1
        }
    }
}

// MARK: - Candidate Scoring

private struct CandidateScore {
    let element: HTMLNode
    var score: Double
}

private extension ReadabilityExtractor {

    /// Block-level tags that are candidates for article containers.
    static let candidateTags: Set<String> = [
        "div", "section", "article", "td", "pre", "blockquote",
        "main", "aside", "details", "figure"
    ]

    /// Positive class/id name patterns.
    static let positivePatterns: [String] = [
        "article", "body", "content", "post", "text", "story",
        "entry", "main", "blog", "page"
    ]

    /// Negative class/id name patterns.
    static let negativePatterns: [String] = [
        "comment", "nav", "sidebar", "footer", "header", "menu",
        "ad", "social", "share", "related", "widget", "promo",
        "sponsor", "popup", "modal", "banner", "cookie", "consent"
    ]

    static func scoreCandidates(node: HTMLNode, candidates: inout [CandidateScore]) {
        guard case .element(let tag, _) = node.kind else { return }

        if candidateTags.contains(tag) {
            let score = scoreElement(node, tag: tag)
            if score > 0 {
                candidates.append(CandidateScore(element: node, score: score))

                // Propagate score upward
                if let parent = node.parent, parent.tag != "document" {
                    if let parentIdx = candidates.firstIndex(where: { $0.element === node.parent }) {
                        candidates[parentIdx].score += score
                    } else {
                        candidates.append(CandidateScore(element: parent, score: score))
                    }

                    // Grandparent gets half
                    if let grandparent = parent.parent, grandparent.tag != "document" {
                        if let gpIdx = candidates.firstIndex(where: { $0.element === grandparent }) {
                            candidates[gpIdx].score += score / 2
                        } else {
                            candidates.append(CandidateScore(element: grandparent, score: score / 2))
                        }
                    }
                }
            }
        }

        for child in node.children {
            scoreCandidates(node: child, candidates: &candidates)
        }
    }

    static func scoreElement(_ element: HTMLNode, tag: String) -> Double {
        let text = element.textContent
        let textLength = text.filter { !$0.isWhitespace }.count

        // Skip elements with very little text
        guard textLength > 25 else { return 0 }

        var score: Double = 0

        // Base score from content length
        score += min(Double(textLength) / 100.0, 3.0)

        // Paragraph count
        let pCount = countDescendants(element, tag: "p")
        score += Double(pCount)

        // Comma count (prose heuristic)
        let commaCount = text.filter { $0 == "," }.count
        score += Double(commaCount)

        // Link density penalty
        let linkDensity = computeLinkDensity(element)
        score *= (1.0 - linkDensity)

        // Tag-based bonuses
        switch tag {
        case "article": score += 20
        case "section": score += 5
        case "div": score += 5
        case "main": score += 15
        case "aside": score -= 10
        case "blockquote": score += 3
        default: break
        }

        // ID/class-based bonuses
        let idClass = ((element.attribute("id") ?? "") + " " +
                       (element.attribute("class") ?? "")).lowercased()

        for pattern in positivePatterns {
            if idClass.contains(pattern) {
                score += 25
                break
            }
        }

        for pattern in negativePatterns {
            if idClass.contains(pattern) {
                score -= 25
                break
            }
        }

        return score
    }

    static func computeLinkDensity(_ element: HTMLNode) -> Double {
        let totalText = element.textContent
        let totalLen = Double(totalText.filter { !$0.isWhitespace }.count)
        guard totalLen > 0 else { return 0 }

        var linkLen: Double = 0
        collectLinkText(element, linkLen: &linkLen)

        return linkLen / totalLen
    }

    static func collectLinkText(_ node: HTMLNode, linkLen: inout Double) {
        if node.tag == "a" {
            let text = node.textContent.filter { !$0.isWhitespace }
            linkLen += Double(text.count)
            return // Don't recurse into links
        }
        for child in node.children {
            collectLinkText(child, linkLen: &linkLen)
        }
    }

    static func countDescendants(_ node: HTMLNode, tag: String) -> Int {
        var count = 0
        for child in node.children {
            if child.tag == tag { count += 1 }
            count += countDescendants(child, tag: tag)
        }
        return count
    }
}

// MARK: - Post-processing

private extension ReadabilityExtractor {

    static func postProcess(_ element: HTMLNode) {
        // Remove high-link-density children
        element.children.removeAll { child in
            guard child.tag != nil else { return false }

            let density = computeLinkDensity(child)
            let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove if it's a short block that's mostly links
            if density > 0.5 && text.count < 200 { return true }

            // Remove known non-content tags that might still be inside
            let tag = child.tag ?? ""
            if ["aside", "nav", "footer", "header"].contains(tag) { return true }

            // Remove by class/id
            let idClass = ((child.attribute("id") ?? "") + " " +
                           (child.attribute("class") ?? "")).lowercased()
            for pattern in negativePatterns {
                if idClass.contains(pattern) && text.count < 300 { return true }
            }

            return false
        }

        // Recurse
        for child in element.children {
            if child.tag != nil {
                postProcess(child)
            }
        }

        // Remove empty elements
        element.children.removeAll { child in
            guard let tag = child.tag else { return false }
            if HTMLParser.selfClosingTags.contains(tag) { return false }
            if tag == "br" || tag == "hr" { return false }
            return child.children.isEmpty &&
                   child.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Content Extraction Helpers

private extension ReadabilityExtractor {

    static func findFirstHeading(in node: HTMLNode) -> String? {
        for child in node.children {
            if let tag = child.tag, ["h1", "h2"].contains(tag) {
                let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            if let found = findFirstHeading(in: child) {
                return found
            }
        }
        return nil
    }

    static func findFirstParagraphText(in node: HTMLNode) -> String? {
        for child in node.children {
            if child.tag == "p" {
                let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 50 { return String(text.prefix(300)) }
            }
            if let found = findFirstParagraphText(in: child) {
                return found
            }
        }
        return nil
    }
}
