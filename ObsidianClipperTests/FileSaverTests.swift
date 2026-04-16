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

    func testSanitizeSingleDot() {
        let result = FileSaver.sanitizeFilename(".")
        XCTAssertEqual(result, "Untitled", "Single dot should become Untitled")
    }

    func testSanitizeLeadingDots() {
        let result = FileSaver.sanitizeFilename(".hidden-article")
        XCTAssertFalse(result.hasPrefix("."), "Should not start with a dot")
        XCTAssertTrue(result.contains("hidden"), "Should preserve the rest of the name")
    }

    func testSanitizeTrailingDots() {
        let result = FileSaver.sanitizeFilename("Article...")
        XCTAssertFalse(result.hasSuffix("."), "Should not end with dots")
        XCTAssertTrue(result.hasPrefix("Article"), "Should preserve the name")
    }

    func testSanitizeWindowsReservedCON() {
        let result = FileSaver.sanitizeFilename("CON")
        XCTAssertNotEqual(result, "CON", "Should not be a bare Windows reserved name")
    }

    func testSanitizeWindowsReservedNUL() {
        let result = FileSaver.sanitizeFilename("NUL")
        XCTAssertNotEqual(result, "NUL", "Should not be a bare Windows reserved name")
    }

    func testSanitizeWindowsReservedCaseInsensitive() {
        let result = FileSaver.sanitizeFilename("con")
        XCTAssertNotEqual(result.uppercased(), "CON", "Reserved name check should be case-insensitive")
    }

    func testSanitizeWindowsReservedCOM1() {
        let result = FileSaver.sanitizeFilename("COM1")
        XCTAssertNotEqual(result, "COM1", "Should not be a bare Windows reserved name")
    }

    func testSanitizeDotsOnly() {
        let result = FileSaver.sanitizeFilename("...")
        XCTAssertEqual(result, "Untitled", "Only dots should become Untitled")
    }

    // MARK: - FileSaver.save

    func testSaveThrowsNoVaultConfigured() {
        let result = ClipResult(
            title: "Test",
            sourceURL: URL(string: "https://example.com"),
            markdownBody: "Body",
            images: [],
            clippedDate: Date()
        )
        let config = FileSaver.SaveConfig(
            targetFolder: "Inbox",
            includeFrontmatter: true,
            vaultBookmark: nil
        )
        XCTAssertThrowsError(try FileSaver.save(result, config: config)) { error in
            XCTAssertTrue(error is FileSaver.SaveError)
            if let saveError = error as? FileSaver.SaveError {
                switch saveError {
                case .noVaultConfigured:
                    break // expected
                default:
                    XCTFail("Expected noVaultConfigured, got \(saveError)")
                }
            }
        }
    }

    func testSaveThrowsBookmarkResolutionFailed() {
        let result = ClipResult(
            title: "Test",
            sourceURL: URL(string: "https://example.com"),
            markdownBody: "Body",
            images: [],
            clippedDate: Date()
        )
        // Pass invalid bookmark data that can't be resolved
        let config = FileSaver.SaveConfig(
            targetFolder: "Inbox",
            includeFrontmatter: true,
            vaultBookmark: Data([0x00, 0x01, 0x02])
        )
        XCTAssertThrowsError(try FileSaver.save(result, config: config)) { error in
            XCTAssertTrue(error is FileSaver.SaveError, "Should throw SaveError, got: \(error)")
        }
    }
}
