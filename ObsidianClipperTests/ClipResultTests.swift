import XCTest
@testable import ClipperExtension

final class ClipResultTests: XCTestCase {

    private func makeResult(
        title: String = "Test Article",
        sourceURL: URL? = URL(string: "https://example.com/article"),
        markdownBody: String = "Some **bold** content.",
        images: [ExtractedImage] = [],
        clippedDate: Date = Date(timeIntervalSince1970: 1713139200) // 2024-04-15
    ) -> ClipResult {
        ClipResult(
            title: title,
            sourceURL: sourceURL,
            markdownBody: markdownBody,
            images: images,
            clippedDate: clippedDate
        )
    }

    // MARK: - Frontmatter

    func testToMarkdownWithFrontmatter() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: true)
        XCTAssertTrue(md.hasPrefix("---\n"), "Should start with frontmatter delimiter")
        XCTAssertTrue(md.contains("title: \"Test Article\""), "Should include title in frontmatter")
        XCTAssertTrue(md.contains("source: \"https://example.com/article\""), "Should include source URL")
        XCTAssertTrue(md.contains("type: article"), "Should include type")
        XCTAssertTrue(md.contains("clipped:"), "Should include clipped date")
    }

    func testToMarkdownWithoutFrontmatter() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertFalse(md.contains("---\n"), "Should not contain frontmatter delimiter")
        XCTAssertTrue(md.hasPrefix("# Test Article"), "Should start with title heading")
    }

    func testToMarkdownEscapesQuotesInTitle() {
        let result = makeResult(title: "He said \"hello\"")
        let md = result.toMarkdown(includeFrontmatter: true)
        XCTAssertTrue(md.contains("title: \"He said \\\"hello\\\"\""), "Should escape quotes in frontmatter, got: \(md)")
    }

    // MARK: - Title and Source

    func testToMarkdownIncludesH1Title() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertTrue(md.contains("# Test Article"), "Should include H1 title")
    }

    func testToMarkdownIncludesSourceLink() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertTrue(md.contains("[Source](https://example.com/article)"), "Should include source link")
    }

    func testToMarkdownNoSourceURLOmitsLink() {
        let result = makeResult(sourceURL: nil)
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertFalse(md.contains("[Source]"), "Should not include source link when URL is nil")
    }

    // MARK: - Body

    func testToMarkdownIncludesBody() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertTrue(md.contains("Some **bold** content."), "Should include markdown body")
    }

    // MARK: - Image References

    func testToMarkdownWithInlineImageNoFallbackSection() {
        // When images are already inline in the body, no "## Images" section should appear
        let images = [
            ExtractedImage(
                sourceURL: URL(string: "https://example.com/photo.png")!,
                data: Data(),
                filename: "abc-1.png",
                ocrText: nil
            )
        ]
        let body = "Some text\n\n![abc-1](images/abc-1.png)\n\nMore text"
        let result = makeResult(markdownBody: body, images: images)
        let refs = ["https://example.com/photo.png": "images/abc-1.png"]
        let md = result.toMarkdown(includeFrontmatter: false, imageReferences: refs)
        XCTAssertTrue(md.contains("![abc-1](images/abc-1.png)"), "Should contain inline image, got: \(md)")
        XCTAssertFalse(md.contains("## Images"), "Should not have fallback Images section when images are inline")
    }

    func testToMarkdownWithUnreferencedImagesFallback() {
        // When images are NOT inline in the body, they should appear in a fallback section
        let images = [
            ExtractedImage(
                sourceURL: URL(string: "https://example.com/photo.png")!,
                data: Data(),
                filename: "abc-1.png",
                ocrText: nil
            )
        ]
        let result = makeResult(images: images)
        let refs = ["https://example.com/photo.png": "images/abc-1.png"]
        let md = result.toMarkdown(includeFrontmatter: false, imageReferences: refs)
        XCTAssertTrue(md.contains("## Images"), "Should include fallback Images section")
        XCTAssertTrue(md.contains("![abc-1](images/abc-1.png)"), "Should include image reference, got: \(md)")
    }

    func testToMarkdownWithoutImageReferencesNoSection() {
        let result = makeResult()
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertFalse(md.contains("## Images"), "Should not include Images section when no references")
    }

    // MARK: - OCR Text

    func testToMarkdownIncludesOCRText() {
        let images = [
            ExtractedImage(
                sourceURL: URL(string: "https://example.com/photo.png")!,
                data: Data(),
                filename: "abc-1.png",
                ocrText: "Recognized text from image"
            )
        ]
        let result = makeResult(images: images)
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertTrue(md.contains("## Extracted Text (OCR)"), "Should include OCR section")
        XCTAssertTrue(md.contains("Recognized text from image"), "Should include OCR text")
        XCTAssertTrue(md.contains("### abc-1.png"), "Should include image filename as heading")
    }

    func testToMarkdownOmitsOCRSectionWhenNoText() {
        let images = [
            ExtractedImage(
                sourceURL: URL(string: "https://example.com/photo.png")!,
                data: Data(),
                filename: "abc-1.png",
                ocrText: nil
            )
        ]
        let result = makeResult(images: images)
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertFalse(md.contains("## Extracted Text (OCR)"), "Should not include OCR section when no text")
    }

    func testToMarkdownOCRTextAsBlockquote() {
        let images = [
            ExtractedImage(
                sourceURL: URL(string: "https://example.com/photo.png")!,
                data: Data(),
                filename: "abc-1.png",
                ocrText: "Line one\nLine two"
            )
        ]
        let result = makeResult(images: images)
        let md = result.toMarkdown(includeFrontmatter: false)
        XCTAssertTrue(md.contains("> Line one"), "OCR text should be in blockquote format")
        XCTAssertTrue(md.contains("> Line two"), "Multi-line OCR should continue blockquote")
    }
}
