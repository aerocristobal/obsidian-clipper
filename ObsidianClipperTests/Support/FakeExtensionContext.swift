import Foundation

/// Test-only `NSExtensionContext` that returns a caller-supplied input-item
/// list and records completion / cancellation calls. Used by
/// `ShareViewControllerHarnessTests` to drive the share-extension pipeline
/// in-process without depending on the real iOS extension lifecycle.
///
/// `NSExtensionContext` cannot be instantiated freely outside the extension
/// runtime, but its `inputItems`, `completeRequest(returningItems:completionHandler:)`,
/// and `cancelRequest(withError:)` methods are overridable and that is enough
/// to satisfy `WebContentExtractor.extract(from:)` and the
/// `ShareViewController` completion path.
final class FakeExtensionContext: NSExtensionContext {

    private let storedInputItems: [Any]

    /// `true` once `completeRequest(returningItems:completionHandler:)` has been called.
    private(set) var didCompleteRequest = false

    /// `true` once `cancelRequest(withError:)` has been called.
    private(set) var didCancelRequest = false

    /// The error passed to `cancelRequest(withError:)`, if any.
    private(set) var cancelError: Error?

    init(inputItems: [Any]) {
        self.storedInputItems = inputItems
        super.init()
    }

    override var inputItems: [Any] {
        return storedInputItems
    }

    override func completeRequest(
        returningItems items: [Any]?,
        completionHandler: ((Bool) -> Void)? = nil
    ) {
        didCompleteRequest = true
        completionHandler?(true)
    }

    override func cancelRequest(withError error: Error) {
        didCancelRequest = true
        cancelError = error
    }
}

// MARK: - Convenience builders

extension FakeExtensionContext {

    /// Build a context that mimics Safari's share input: a single
    /// `NSExtensionItem` carrying a `public.property-list` provider whose
    /// payload follows the `NSExtensionJavaScriptPreprocessingResultsKey`
    /// shape. This is the path `WebContentExtractor` exercises when Safari
    /// runs `Action.js` and hands the resulting `{title, URL, html}` dict
    /// back to the extension.
    static func safariJSResults(
        title: String,
        url: String,
        html: String
    ) -> FakeExtensionContext {
        let payload: [String: Any] = [
            "title": title,
            "URL": url,
            "html": html,
        ]
        let wrapped: [String: Any] = [
            NSExtensionJavaScriptPreprocessingResultsKey: payload
        ]

        let provider = NSItemProvider(item: wrapped as NSDictionary, typeIdentifier: "public.property-list")

        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: title)
        item.attachments = [provider]

        return FakeExtensionContext(inputItems: [item])
    }

    /// Build a context that carries a single `public.url` provider — the
    /// shape used when another app shares only a URL and the extension has
    /// to fetch the page itself. **This will trigger network access**, so
    /// only use it when you've stubbed `URLSession` or the test is OK with
    /// real fetches.
    static func urlOnly(url: String) -> FakeExtensionContext {
        guard let parsed = URL(string: url) else {
            return FakeExtensionContext(inputItems: [])
        }
        let provider = NSItemProvider(item: parsed as NSURL, typeIdentifier: "public.url")
        let item = NSExtensionItem()
        item.attachments = [provider]
        return FakeExtensionContext(inputItems: [item])
    }
}
