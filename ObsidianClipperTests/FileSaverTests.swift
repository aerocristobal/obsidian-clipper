import XCTest
@testable import ClipperExtension

final class FileSaverTests: XCTestCase {

    // MARK: - sanitizeFilename

    func testSanitizeBasicFilename() {
        let result = FileSaver.sanitizeFilename("My Article Title")
        XCTAssertEqual(result, "My Article Title")
    }

    func testSanitizeRemovesInvalidCharacters() {
        let result = FileSaver.sanitizeFilename("Title: With / Invalid * Chars?")
        XCTAssertFalse(result.contains(":"), "Should remove colons")
        XCTAssertFalse(result.contains("/"), "Should remove slashes")
        XCTAssertFalse(result.contains("*"), "Should remove asterisks")
        XCTAssertFalse(result.contains("?"), "Should remove question marks")
    }

    func testSanitizeCollapsesDashes() {
        let result = FileSaver.sanitizeFilename("A:::B")
        XCTAssertFalse(result.contains("---"), "Should collapse multiple dashes")
    }

    func testSanitizeLongName() {
        let longTitle = String(repeating: "A", count: 300)
        let result = FileSaver.sanitizeFilename(longTitle)
        XCTAssertLessThanOrEqual(result.count, 200, "Should truncate to 200 chars")
    }

    func testSanitizeEmptyName() {
        let result = FileSaver.sanitizeFilename("")
        XCTAssertEqual(result, "Untitled")
    }

    func testSanitizeOnlyInvalidChars() {
        let result = FileSaver.sanitizeFilename(":::**??")
        XCTAssertEqual(result, "Untitled")
    }

    func testSanitizeTrimsWhitespace() {
        let result = FileSaver.sanitizeFilename("  Title  ")
        XCTAssertEqual(result, "Title")
    }

    func testSanitizeTrimsDashes() {
        let result = FileSaver.sanitizeFilename("--Title--")
        XCTAssertEqual(result, "Title")
    }

    func testSanitizeBackslash() {
        let result = FileSaver.sanitizeFilename("Path\\To\\File")
        XCTAssertFalse(result.contains("\\"), "Should remove backslashes")
    }

    func testSanitizeAngleBrackets() {
        let result = FileSaver.sanitizeFilename("<script>alert</script>")
        XCTAssertFalse(result.contains("<"), "Should remove angle brackets")
        XCTAssertFalse(result.contains(">"), "Should remove angle brackets")
    }

    func testSanitizePipeCharacter() {
        let result = FileSaver.sanitizeFilename("Title | Subtitle")
        XCTAssertFalse(result.contains("|"), "Should remove pipe characters")
    }

    func testSanitizeQuotes() {
        let result = FileSaver.sanitizeFilename("\"Quoted\" Title")
        XCTAssertFalse(result.contains("\""), "Should remove double quotes")
    }

    func testSanitizeUnicode() {
        let result = FileSaver.sanitizeFilename("Cafe Resume")
        XCTAssertEqual(result, "Cafe Resume")
    }

    func testSanitizeSpecialCharCombo() {
        let result = FileSaver.sanitizeFilename("A/B:C*D?E\"F<G>H|I\\J")
        XCTAssertFalse(result.isEmpty, "Should produce non-empty result")
        XCTAssertTrue(result.contains("A"), "Should preserve valid characters")
        XCTAssertTrue(result.contains("J"), "Should preserve valid characters")
    }
}
