import XCTest
@testable import ClipperExtension

final class WebContentExtractorTests: XCTestCase {

    // MARK: - detectURL

    func testDetectURLPlainHTTPS() {
        let url = WebContentExtractor.detectURL(in: "https://example.com/article")
        XCTAssertEqual(url?.absoluteString, "https://example.com/article")
    }

    func testDetectURLPlainHTTP() {
        let url = WebContentExtractor.detectURL(in: "http://example.com")
        XCTAssertEqual(url?.absoluteString, "http://example.com")
    }

    func testDetectURLEmbeddedInText() {
        let url = WebContentExtractor.detectURL(in: "Check out https://example.com/page for more")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "example.com")
    }

    func testDetectURLWithWhitespace() {
        let url = WebContentExtractor.detectURL(in: "  https://example.com  ")
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testDetectURLNoURL() {
        let url = WebContentExtractor.detectURL(in: "Just some plain text")
        XCTAssertNil(url)
    }

    func testDetectURLEmptyString() {
        let url = WebContentExtractor.detectURL(in: "")
        XCTAssertNil(url)
    }

    // MARK: - detectEncoding

    func testDetectEncodingUTF8() {
        let response = makeResponse(contentType: "text/html; charset=utf-8")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingISO88591() {
        let response = makeResponse(contentType: "text/html; charset=iso-8859-1")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .isoLatin1)
    }

    func testDetectEncodingLatin1Alias() {
        let response = makeResponse(contentType: "text/html; charset=latin1")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .isoLatin1)
    }

    func testDetectEncodingWindows1252() {
        let response = makeResponse(contentType: "text/html; charset=windows-1252")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .windowsCP1252)
    }

    func testDetectEncodingASCII() {
        let response = makeResponse(contentType: "text/html; charset=ascii")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .ascii)
    }

    func testDetectEncodingUTF16() {
        let response = makeResponse(contentType: "text/html; charset=utf-16")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf16)
    }

    func testDetectEncodingNoCharset() {
        let response = makeResponse(contentType: "text/html")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingNoContentType() {
        let response = makeResponse(contentType: nil)
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8)
    }

    func testDetectEncodingUnknownCharset() {
        let response = makeResponse(contentType: "text/html; charset=some-unknown")
        XCTAssertEqual(WebContentExtractor.detectEncoding(from: response), .utf8) // falls back to utf8
    }

    // MARK: - extractTitle

    func testExtractTitleBasic() {
        let title = WebContentExtractor.extractTitle(from: "<html><head><title>My Page</title></head></html>")
        XCTAssertEqual(title, "My Page")
    }

    func testExtractTitleWithEntities() {
        let title = WebContentExtractor.extractTitle(from: "<title>A &amp; B &lt;C&gt;</title>")
        XCTAssertEqual(title, "A & B <C>")
    }

    func testExtractTitleWithApostrophe() {
        let title = WebContentExtractor.extractTitle(from: "<title>It&#39;s a test</title>")
        XCTAssertEqual(title, "It's a test")
    }

    func testExtractTitleMissing() {
        let title = WebContentExtractor.extractTitle(from: "<html><head></head></html>")
        XCTAssertNil(title)
    }

    func testExtractTitleEmpty() {
        let title = WebContentExtractor.extractTitle(from: "<title></title>")
        XCTAssertEqual(title, "")
    }

    func testExtractTitleMultiline() {
        let title = WebContentExtractor.extractTitle(from: "<title>Line One\nLine Two</title>")
        XCTAssertEqual(title, "Line One\nLine Two")
    }

    // MARK: - Helpers

    private func makeResponse(contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let ct = contentType {
            headers["Content-Type"] = ct
        }
        return HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
