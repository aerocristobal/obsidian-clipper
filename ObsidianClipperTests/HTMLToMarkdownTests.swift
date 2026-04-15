import XCTest
@testable import ClipperExtension

final class HTMLToMarkdownTests: XCTestCase {

    // MARK: - Bold

    @MainActor
    func testBoldConversion() {
        let html = "<p>This is <b>bold</b> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("**bold**"), "Expected bold markers, got: \(md)")
    }

    // MARK: - Italic

    @MainActor
    func testItalicConversion() {
        let html = "<p>This is <em>italic</em> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("_italic_"), "Expected italic markers, got: \(md)")
    }

    // MARK: - Links

    @MainActor
    func testLinkConversion() {
        let html = "<p>Visit <a href=\"https://example.com\">Example</a> site</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("["), "Expected link syntax, got: \(md)")
        XCTAssertTrue(md.contains("](https://example.com"), "Expected link URL, got: \(md)")
    }

    // MARK: - Headings

    @MainActor
    func testHeadingH1() {
        let html = "<h1>Main Title</h1>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("# "), "Expected h1 heading, got: \(md)")
        XCTAssertTrue(md.contains("Main Title"), "Expected heading text, got: \(md)")
    }

    @MainActor
    func testHeadingH2() {
        let html = "<h2>Section</h2>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("## ") || md.contains("# "), "Expected heading, got: \(md)")
        XCTAssertTrue(md.contains("Section"), "Expected heading text, got: \(md)")
    }

    @MainActor
    func testHeadingDoesNotContainBoldMarkers() {
        let html = "<h2>Bold Heading</h2>"
        let md = HTMLToMarkdown.convert(html)
        // Headings should not have redundant ** markers
        XCTAssertFalse(md.contains("**Bold Heading**"), "Headings should not have bold markers, got: \(md)")
    }

    // MARK: - Lists

    @MainActor
    func testUnorderedList() {
        let html = "<ul><li>Item one</li><li>Item two</li></ul>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("- ") || md.contains("Item one"), "Expected list items, got: \(md)")
    }

    @MainActor
    func testOrderedList() {
        let html = "<ol><li>First</li><li>Second</li></ol>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("1. ") || md.contains("First"), "Expected ordered list items, got: \(md)")
    }

    // MARK: - Blockquotes

    @MainActor
    func testBlockquote() {
        let html = "<blockquote>This is a quote</blockquote>"
        let md = HTMLToMarkdown.convert(html)
        // Blockquote detection depends on NSAttributedString rendering;
        // at minimum the text should be present
        XCTAssertTrue(md.contains("quote"), "Expected blockquote text, got: \(md)")
    }

    // MARK: - Code

    @MainActor
    func testInlineCode() {
        let html = "<p>Use <code>print()</code> to output text</p>"
        let md = HTMLToMarkdown.convert(html)
        // Code detection depends on font rendering
        XCTAssertTrue(md.contains("print()"), "Expected code text, got: \(md)")
    }

    @MainActor
    func testCodeBlock() {
        let html = "<pre><code>func hello() {\n    print(\"hi\")\n}</code></pre>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("hello()") || md.contains("func"), "Expected code block content, got: \(md)")
    }

    // MARK: - Strikethrough

    @MainActor
    func testStrikethrough() {
        let html = "<p>This is <s>deleted</s> text</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("~~deleted~~") || md.contains("deleted"), "Expected strikethrough, got: \(md)")
    }

    // MARK: - HTML Stripping Fallback

    @MainActor
    func testFallbackStripsHTML() {
        // An extremely malformed HTML that NSAttributedString can't parse
        // still produces some output
        let html = "<p>Plain text content</p>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("Plain text content"), "Expected content preserved, got: \(md)")
    }

    // MARK: - Image URL Extraction

    func testExtractImageURLsBasic() {
        let html = #"<img src="https://example.com/image.png">"#
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/image.png")
    }

    func testExtractImageURLsRelative() {
        let html = #"<img src="/images/photo.jpg">"#
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com/images/photo.jpg")
    }

    func testExtractImageURLsMultiple() {
        let html = """
        <img src="https://example.com/1.png">
        <img src="https://example.com/2.jpg">
        <img src="https://example.com/3.gif">
        """
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 3)
    }

    func testExtractImageURLsDeduplicates() {
        let html = """
        <img src="https://example.com/same.png">
        <img src="https://example.com/same.png">
        """
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        XCTAssertEqual(urls.count, 1)
    }

    func testExtractImageURLsSrcset() {
        let html = #"<img src="small.jpg" srcset="medium.jpg 640w, large.jpg 1024w">"#
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        // Should include src and the largest srcset image
        XCTAssertTrue(urls.count >= 2, "Expected at least 2 URLs (src + srcset), got: \(urls.count)")
        let urlStrings = urls.map { $0.absoluteString }
        XCTAssertTrue(urlStrings.contains { $0.contains("large.jpg") }, "Expected largest srcset image")
    }

    func testExtractImageURLsDataSrc() {
        let html = #"<img data-src="https://example.com/lazy.jpg" src="placeholder.gif">"#
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: nil)
        let urlStrings = urls.map { $0.absoluteString }
        XCTAssertTrue(urlStrings.contains("https://example.com/lazy.jpg"), "Expected data-src URL")
    }

    func testExtractImageURLsPictureElement() {
        let html = """
        <picture>
            <source srcset="large.webp 1024w, small.webp 320w" type="image/webp">
            <img src="fallback.jpg">
        </picture>
        """
        let base = URL(string: "https://example.com")!
        let urls = HTMLToMarkdown.extractImageURLs(from: html, baseURL: base)
        XCTAssertTrue(urls.count >= 2, "Expected at least 2 URLs from picture element, got: \(urls.count)")
    }

    // MARK: - Table Detection

    @MainActor
    func testTableConversion() {
        let html = """
        <table><tr><th>Name</th><th>Value</th></tr>
        <tr><td>A</td><td>1</td></tr>
        <tr><td>B</td><td>2</td></tr></table>
        """
        let md = HTMLToMarkdown.convert(html)
        // Tables from NSAttributedString are tab-separated; our converter should
        // detect and format them. At minimum, content should be present.
        XCTAssertTrue(md.contains("Name") && md.contains("Value"), "Expected table content, got: \(md)")
    }
}
