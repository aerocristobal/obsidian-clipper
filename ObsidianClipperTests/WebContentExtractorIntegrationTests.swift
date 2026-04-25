import XCTest
@testable import ClipperExtension

/// Integration test for `WebContentExtractor.extract(from:)` exercised through
/// a mocked `NSExtensionContext`. Each test case mirrors a real attachment
/// shape we suspect Safari (or another sharing app) might be sending. The
/// `[Clipper.input]` NSLog output produced by `WebContentExtractor` lands in
/// xcodebuild's stdout, where `scripts/test-share-input.sh` filters it.
///
/// This is NOT a behavior-correctness test (no assertions on RawContent — the
/// scenarios are designed to surface what the extractor logs, not to assert
/// pass/fail). The user reads the captured log lines to diagnose where the
/// share-input pipeline breaks.
final class WebContentExtractorIntegrationTests: XCTestCase {

    // MARK: - Mock NSExtensionContext

    /// Minimal mock so we can hand a synthetic input-items list to
    /// `WebContentExtractor.extract`. `inputItems` is the only property the
    /// extractor reads from the context.
    private final class MockExtensionContext: NSExtensionContext {
        let mockInputItems: [NSExtensionItem]
        init(items: [NSExtensionItem]) {
            self.mockInputItems = items
            super.init()
        }
        override var inputItems: [Any] { mockInputItems }
    }

    private func runExtract(scenarioName: String, items: [NSExtensionItem]) async {
        NSLog("[Clipper.input] === scenario: %@ ===", scenarioName)
        let context = MockExtensionContext(items: items)
        let result = await WebContentExtractor.extract(from: context)
        NSLog("[Clipper.input] result: title=%@ url=%@ html_len=%d",
              result?.title ?? "nil",
              result?.url?.absoluteString ?? "nil",
              result?.html?.count ?? -1)
        NSLog("[Clipper.input] === end scenario: %@ ===", scenarioName)
    }

    // MARK: - Scenarios

    /// Scenario 1: Safari-style — single item with two providers, one with
    /// `public.url`, one with `public.property-list` carrying JS results.
    /// This is what Safari sends when `Action.js` runs successfully.
    func testSafariStyleURLPlusPropertyList() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Test page title | Example")

        let urlProvider = NSItemProvider(item: URL(string: "https://example.com/article")! as NSURL,
                                         typeIdentifier: "public.url")
        let plistData: [String: Any] = [
            NSExtensionJavaScriptPreprocessingResultsKey: [
                "title": "Test page title",
                "URL": "https://example.com/article",
                "html": "<html><body><p>Body content for the test article.</p></body></html>"
            ]
        ]
        let plistProvider = NSItemProvider(item: plistData as NSDictionary,
                                           typeIdentifier: "public.property-list")

        item.attachments = [urlProvider, plistProvider]
        await runExtract(scenarioName: "safari-url-plus-plist", items: [item])
    }

    /// Scenario 2: Safari but property-list comes back FLAT (no
    /// `NSExtensionJavaScriptPreprocessingResultsKey` wrapping). Tests our
    /// fallback handling of that shape.
    func testSafariStyleFlatPropertyList() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "Test page title | Example")

        let urlProvider = NSItemProvider(item: URL(string: "https://example.com/article")! as NSURL,
                                         typeIdentifier: "public.url")
        let flatPlistData: [String: Any] = [
            "title": "Test page title",
            "URL": "https://example.com/article",
            "html": "<html><body><p>Body content via flat dict.</p></body></html>"
        ]
        let plistProvider = NSItemProvider(item: flatPlistData as NSDictionary,
                                           typeIdentifier: "public.property-list")

        item.attachments = [urlProvider, plistProvider]
        await runExtract(scenarioName: "safari-flat-plist", items: [item])
    }

    /// Scenario 3: URL provider returns NSURL (not URL). Tests our cast
    /// fallback `as? NSURL`.
    func testURLAsNSURL() async {
        let item = NSExtensionItem()
        let nsurl = NSURL(string: "https://example.com/page")!
        let urlProvider = NSItemProvider(item: nsurl, typeIdentifier: "public.url")
        item.attachments = [urlProvider]
        await runExtract(scenarioName: "url-as-nsurl", items: [item])
    }

    /// Scenario 4: URL provider returns a String (not URL). Tests our
    /// `as? String` -> `URL(string:)` fallback.
    func testURLAsString() async {
        let item = NSExtensionItem()
        let urlProvider = NSItemProvider(item: "https://example.com/page" as NSString,
                                         typeIdentifier: "public.url")
        item.attachments = [urlProvider]
        await runExtract(scenarioName: "url-as-string", items: [item])
    }

    /// Scenario 5: only a public.url attachment — what Safari sends if
    /// `Action.js` doesn't run (or runs too slow). HTML must come from
    /// the server fetch.
    func testURLOnlyForcesServerFetch() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: "example.com")
        let urlProvider = NSItemProvider(item: URL(string: "https://example.com/")! as NSURL,
                                         typeIdentifier: "public.url")
        item.attachments = [urlProvider]
        await runExtract(scenarioName: "url-only-server-fetch", items: [item])
    }

    /// Scenario 6: empty share — no attachments. Should hit the `nil` path.
    func testEmptyContext() async {
        let item = NSExtensionItem()
        item.attachments = []
        await runExtract(scenarioName: "empty-context", items: [item])
    }

    /// Scenario 7: plain-text only (some apps share URLs as plain text).
    func testPlainTextURL() async {
        let item = NSExtensionItem()
        let textProvider = NSItemProvider(item: "Check this out: https://example.com/path" as NSString,
                                          typeIdentifier: "public.plain-text")
        item.attachments = [textProvider]
        await runExtract(scenarioName: "plain-text-with-url", items: [item])
    }
}
