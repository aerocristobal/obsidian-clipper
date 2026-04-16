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

    // MARK: - detectEncoding (body-aware / meta tag fallback)

    func testDetectEncodingHeaderWinsOverMeta() {
        let response = makeResponse(contentType: "text/html; charset=utf-8")
        let body = #"<html><head><meta charset="iso-8859-1"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8,
            "HTTP Content-Type charset should take precedence over meta tag"
        )
    }

    func testDetectEncodingFallsBackToMetaCharset() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta charset="iso-8859-1"><title>x</title></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .isoLatin1
        )
    }

    func testDetectEncodingFallsBackToHttpEquivMeta() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .windowsCP1252
        )
    }

    func testDetectEncodingNoCharsetAnywhereDefaultsToUTF8() {
        let response = makeResponse(contentType: "text/html")
        let body = "<html><head><title>no charset</title></head></html>".data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8
        )
    }

    func testDetectEncodingMetaShiftJIS() {
        let response = makeResponse(contentType: "text/html")
        let body = #"<html><head><meta charset="shift_jis"></head></html>"#.data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .shiftJIS
        )
    }

    func testDetectEncodingMetaSingleQuotes() {
        let response = makeResponse(contentType: "text/html")
        let body = "<meta charset='windows-1251'>".data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .windowsCP1251
        )
    }

    func testDetectEncodingMetaBeyondFirstKBIgnored() {
        let response = makeResponse(contentType: "text/html")
        // Pad with >1KB of whitespace before the meta tag — should NOT be found.
        let padding = String(repeating: " ", count: 1100)
        let body = ("<html>" + padding + #"<meta charset="iso-8859-1">"# + "</html>").data(using: .ascii)!
        XCTAssertEqual(
            WebContentExtractor.detectEncoding(response: response, body: body),
            .utf8,
            "Meta tags beyond the first ~1KB should not be parsed"
        )
    }

    // MARK: - isAllowedScheme (Story 3.1)

    func testAllowedSchemeHTTPS() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "https://example.com")!))
    }

    func testAllowedSchemeHTTP() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "http://example.com")!))
    }

    func testAllowedSchemeHTTPSUppercase() {
        XCTAssertTrue(WebContentExtractor.isAllowedScheme(URL(string: "HTTPS://example.com")!))
    }

    func testRejectedSchemeFile() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "file:///etc/passwd")!))
    }

    func testRejectedSchemeJavaScript() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "javascript:alert(1)")!))
    }

    func testRejectedSchemeFTP() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "ftp://example.com/file")!))
    }

    func testRejectedSchemeData() {
        XCTAssertFalse(WebContentExtractor.isAllowedScheme(URL(string: "data:text/html,<h1>hi</h1>")!))
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
