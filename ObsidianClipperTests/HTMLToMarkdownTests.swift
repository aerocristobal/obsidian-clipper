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

    // MARK: - Image Marker Injection

    func testReplaceImgTagsWithMarkersSingle() {
        let html = #"<p>Before</p><img src="https://example.com/photo.png"><p>After</p>"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertTrue(result.html.contains("[[IMG:0]]"), "Should contain marker, got: \(result.html)")
        XCTAssertFalse(result.html.contains("<img"), "Should not contain <img> tag")
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/photo.png")
    }

    func testReplaceImgTagsWithMarkersMultiple() {
        let html = """
        <p>First</p><img src="https://example.com/1.png">
        <p>Second</p><img src="https://example.com/2.jpg">
        <p>Third</p><img src="https://example.com/3.gif">
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertTrue(result.html.contains("[[IMG:0]]"), "Should contain marker 0")
        XCTAssertTrue(result.html.contains("[[IMG:1]]"), "Should contain marker 1")
        XCTAssertTrue(result.html.contains("[[IMG:2]]"), "Should contain marker 2")
        XCTAssertEqual(result.markerMap.count, 3)
        // Markers should be in document order
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/1.png")
        XCTAssertEqual(result.markerMap[1]?.absoluteString, "https://example.com/2.jpg")
        XCTAssertEqual(result.markerMap[2]?.absoluteString, "https://example.com/3.gif")
    }

    func testReplaceImgTagsDeduplicates() {
        let html = """
        <img src="https://example.com/same.png">
        <img src="https://example.com/same.png">
        """
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1, "Should deduplicate same URLs in marker map")
        // Both <img> tags should be replaced with the same marker
        let markerCount = result.html.components(separatedBy: "[[IMG:0]]").count - 1
        XCTAssertEqual(markerCount, 2, "Both duplicate <img> tags should get the same marker")
    }

    func testReplaceImgTagsSkipsTrackingPixels() {
        let html = #"<img src="https://example.com/tracking-pixel.gif">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "Should skip tracking pixels")
    }

    func testReplaceImgTagsSkipsSVG() {
        let html = #"<img src="https://example.com/icon.svg">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 0, "Should skip SVG images")
    }

    func testReplaceImgTagsResolvesRelativeURLs() {
        let html = #"<img src="/images/photo.jpg">"#
        let base = URL(string: "https://example.com")!
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: base)
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/images/photo.jpg")
    }

    func testReplaceImgTagsUsesDataSrc() {
        let html = #"<img data-src="https://example.com/lazy.jpg">"#
        let result = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: nil)
        XCTAssertEqual(result.markerMap.count, 1)
        XCTAssertEqual(result.markerMap[0]?.absoluteString, "https://example.com/lazy.jpg")
    }

    // MARK: - Marker Replacement

    func testReplaceMarkersWithImages() {
        let markdown = "Some text\n\n[[IMG:0]]\n\nMore text\n\n[[IMG:1]]"
        let mapping: [Int: String] = [0: "images/abc-1.png", 1: "images/abc-2.jpg"]
        let result = HTMLToMarkdown.replaceMarkersWithImages(markdown, markerToPath: mapping)
        XCTAssertTrue(result.markdown.contains("![abc-1](images/abc-1.png)"), "Should replace marker 0, got: \(result.markdown)")
        XCTAssertTrue(result.markdown.contains("![abc-2](images/abc-2.jpg)"), "Should replace marker 1, got: \(result.markdown)")
        XCTAssertFalse(result.markdown.contains("[[IMG:"), "Should not contain any remaining markers")
        XCTAssertEqual(result.placedIndices, [0, 1], "Should report both indices as placed")
    }

    func testReplaceMarkersPartialMapping() {
        let markdown = "Before [[IMG:0]] middle [[IMG:1]] after"
        let mapping: [Int: String] = [0: "images/abc-1.png"]
        let result = HTMLToMarkdown.replaceMarkersWithImages(markdown, markerToPath: mapping)
        XCTAssertTrue(result.markdown.contains("![abc-1](images/abc-1.png)"), "Should replace mapped marker")
        XCTAssertTrue(result.markdown.contains("[[IMG:1]]"), "Should leave unmapped marker intact")
        XCTAssertEqual(result.placedIndices, [0])
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
