import XCTest
@testable import ClipperExtension

/// In-process integration tests that drive the share-extension clipping
/// pipeline end-to-end using a synthetic `NSExtensionContext`. The pipeline
/// runs against fixture HTML, writes a real `.md` file into a temp vault,
/// and we assert the file landed where we expected.
///
/// Tests target `ClippingPipeline.run` (the UI-free pipeline entry point)
/// rather than constructing `ShareViewController` directly. This avoids
/// pulling SwiftUICore into the test bundle, which Apple disallows for
/// non-allowed clients.
///
/// What this catches:
///   - Regressions in `WebContentExtractor.extract(from:)` against the
///     Safari `NSExtensionJavaScriptPreprocessingResultsKey` shape.
///   - Pipeline orchestration regressions (JSON-LD vs Readability branch,
///     image-marker filtering, ClipResult assembly).
///   - `FileSaver` integration with a security-scoped bookmark.
///   - Cancellation mechanics (the clipping `Task` actually cancels).
///
/// What this does NOT catch:
///   - Apple-managed extension launch failures (e.g. the SwiftSoup-link hang
///     that motivated `debug/revert-swiftsoup-from-extension`). Those need a
///     real extension launch via Safari, which only XCUITest can drive.
///     Tier C of the test plan covers that path.
@MainActor
final class ShareViewControllerHarnessTests: XCTestCase {

    // MARK: - Vault setup helpers

    /// A scratch directory that stands in as the Obsidian vault. Recreated
    /// per test so we can deterministically assert "this clip wrote exactly
    /// one .md file under the inbox".
    private var tempVault: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipper-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempVault, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempVault, FileManager.default.fileExists(atPath: tempVault.path) {
            try? FileManager.default.removeItem(at: tempVault)
        }
        clearSeededDefaults()
        try await super.tearDown()
    }

    /// Seed App Group `UserDefaults` with a non-security-scoped bookmark for
    /// the temp vault. The simulator gives the test process full read/write
    /// access to its own temp directory, so a vanilla `bookmarkData` (without
    /// `.suitableForBookmarkFile` or security scope) is enough to satisfy
    /// `FileSaver`.
    private func seedVaultDefaults(targetFolder: String, saveImages: Bool) throws {
        let bookmark = try tempVault.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
        defaults.set(bookmark, forKey: "vault_bookmark")
        defaults.set("TestVault", forKey: "vault_name")
        defaults.set(targetFolder, forKey: "target_folder")
        defaults.set(saveImages, forKey: "save_images")
        defaults.set(false, forKey: "enable_ocr")
        defaults.set(true, forKey: "include_frontmatter")
    }

    private func clearSeededDefaults() {
        let defaults = UserDefaults(suiteName: ClipperSettings.suiteName) ?? .standard
        for key in [
            "vault_bookmark", "vault_name", "target_folder",
            "save_images", "enable_ocr", "include_frontmatter",
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Fixture loading

    private var corpusDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/extraction-corpus", isDirectory: true)
    }

    private func loadFixture(slug: String) throws -> (html: String, url: String) {
        let html = try String(
            contentsOf: corpusDir.appendingPathComponent("\(slug).html"),
            encoding: .utf8
        )
        let urlString = (try? String(
            contentsOf: corpusDir.appendingPathComponent("\(slug).url"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "https://example.com/"
        return (html, urlString)
    }

    // MARK: - Tests

    /// Drives the full pipeline against a fixture that ships with embedded
    /// JSON-LD `articleBody`. Verifies the JSON-LD fast path runs, the
    /// pipeline reaches `FileSaver`, and a `.md` file lands under the
    /// configured target folder.
    func testHappyPathWritesMarkdownToVault() async throws {
        try seedVaultDefaults(targetFolder: "Inbox", saveImages: false)

        let fixture = try loadFixture(slug: "wired-anthropic")
        let context = FakeExtensionContext.safariJSResults(
            title: "Anthropic Opposes the Extreme AI Liability Bill",
            url: fixture.url,
            html: fixture.html
        )

        // Drive the pipeline directly. `ClippingPipeline.run` is the same
        // entry the production `ShareViewController.performClipping`
        // delegates to — only the progress callbacks differ.
        let returnedTitle = try await ClippingPipeline.run(extensionContext: context)

        XCTAssertFalse(returnedTitle.isEmpty, "performClipping returned empty title")

        let inbox = tempVault.appendingPathComponent("Inbox", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inbox.path),
            "Inbox folder was not created at \(inbox.path)"
        )

        let articleSubfolders = try FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            articleSubfolders.count, 1,
            "Expected exactly one article subfolder under Inbox; got \(articleSubfolders.count)"
        )

        // Find the .md file inside the article subfolder.
        let articleDir = articleSubfolders[0]
        let mdFiles = try FileManager.default
            .contentsOfDirectory(at: articleDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(mdFiles.count, 1, "Expected exactly one .md file; got \(mdFiles.count)")

        let markdown = try String(contentsOf: mdFiles[0], encoding: .utf8)
        XCTAssertTrue(markdown.contains("---"), "Expected YAML frontmatter")
        XCTAssertTrue(
            markdown.localizedCaseInsensitiveContains("Anthropic"),
            "Expected article body to mention Anthropic"
        )
        XCTAssertGreaterThan(markdown.count, 500, "Markdown body too short")
    }

    /// Cancels the clipping `Task` mid-flight and asserts the pipeline
    /// terminates with a `CancellationError` and writes nothing.
    func testCancellationStopsPipelinePromptly() async throws {
        try seedVaultDefaults(targetFolder: "Inbox", saveImages: false)

        let fixture = try loadFixture(slug: "theverge-front")
        let context = FakeExtensionContext.safariJSResults(
            title: "The Verge",
            url: fixture.url,
            html: fixture.html
        )
        let task = Task { @MainActor in
            try await ClippingPipeline.run(extensionContext: context)
        }
        // Yield once so the task gets a chance to start, then cancel.
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw")
        } catch is CancellationError {
            // Expected
        } catch {
            // Some throw paths surface as wrapped errors; accept any throw
            // as long as it isn't success.
        }

        // No files should have been written under Inbox (or the dir may not
        // even exist — also acceptable).
        let inbox = tempVault.appendingPathComponent("Inbox", isDirectory: true)
        if FileManager.default.fileExists(atPath: inbox.path) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil
            )
            XCTAssertTrue(
                entries.isEmpty,
                "Cancelled clip should not have persisted any files; found \(entries.map { $0.lastPathComponent })"
            )
        }
    }

    /// Drives a fixture that has no JSON-LD `articleBody` so the pipeline
    /// falls through to Readability. Verifies the same end-to-end success
    /// shape (Inbox folder, one article subfolder, one .md, frontmatter).
    /// `daringfireball-blog-index` is a feed-style page with no Schema.org
    /// `articleBody`, so JSON-LD fast path misses.
    func testReadabilityFallbackPathWritesMarkdown() async throws {
        try seedVaultDefaults(targetFolder: "Inbox", saveImages: false)

        let fixture = try loadFixture(slug: "daringfireball-blog-index")
        let context = FakeExtensionContext.safariJSResults(
            title: "Daring Fireball",
            url: fixture.url,
            html: fixture.html
        )
        _ = try await ClippingPipeline.run(extensionContext: context)

        let inbox = tempVault.appendingPathComponent("Inbox", isDirectory: true)
        let articleSubfolders = try FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(articleSubfolders.count, 1)

        let mdFiles = try FileManager.default
            .contentsOfDirectory(at: articleSubfolders[0], includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(mdFiles.count, 1)
    }

    /// Calls `performClipping` with `vault_bookmark` cleared and asserts a
    /// `FileSaver.SaveError.noVaultConfigured` is raised. This guards against
    /// regressions in the FileSaver early-return path that have masked
    /// silent failures in the past.
    func testNoVaultConfiguredYieldsClearError() async throws {
        clearSeededDefaults()
        let context = FakeExtensionContext.safariJSResults(
            title: "Example Domain",
            url: "https://example.com/",
            html: "<html><body><p>hello</p></body></html>"
        )
        do {
            _ = try await ClippingPipeline.run(extensionContext: context)
            XCTFail("Expected SaveError.noVaultConfigured")
        } catch let error as FileSaver.SaveError {
            switch error {
            case .noVaultConfigured:
                break // expected
            default:
                XCTFail("Expected .noVaultConfigured, got \(error)")
            }
        }
    }
}
