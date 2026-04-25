import UIKit
import SwiftUI
import CryptoKit

// MARK: - View Model

/// Observable view model for the share extension UI.
/// SwiftUI automatically tracks property changes via the Observation framework (iOS 17+).
@Observable
@MainActor
final class ShareViewModel {

    enum ClipState: Equatable {
        case loading(String)
        case success(String)
        case error(String)
    }

    var state: ClipState = .loading("Extracting content…")
}

// MARK: - ShareViewController

/// The Share Extension entry point. Receives content from Safari (or any app)
/// via the Share Sheet, orchestrates the clipping pipeline, and presents a
/// SwiftUI progress/result UI.
final class ShareViewController: UIViewController {

    private let viewModel = ShareViewModel()
    /// Guards against double-completion of the extension context.
    /// Accessed from both the main-actor Task and UI callbacks, so
    /// we protect it with an os_unfair_lock for thread safety.
    private var didComplete = false
    private let didCompleteLock = NSLock()
    /// Handle to the clipping Task so we can cancel it when the user taps Cancel.
    private var clippingTask: Task<Void, Never>?
    /// Held so the cancel path can tear down the scratch directory used for
    /// streamed image temp files. Retained until success cleanup or cancel.
    private var imageProcessor: ImageProcessor?
    /// Token for the `didReceiveMemoryWarningNotification` observer. Retained
    /// so `deinit` can remove it explicitly. Block-based observers are not
    /// auto-removed, unlike selector-based ones.
    private var memoryWarningObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        registerMemoryWarningObserver()
        startClipping()
    }

    deinit {
        if let token = memoryWarningObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Memory Warnings

    /// Listen for system memory pressure. If image processing is in flight,
    /// throttle the processor's concurrency cap down to 1 so no new tasks are
    /// seeded. If the processor is nil (e.g. success state, idle) this is a
    /// no-op — which satisfies the "no crash during idle" requirement.
    private func registerMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard let processor = self.imageProcessor else { return }
            // Hop onto the actor; the notification fires on main.
            Task { await processor.reduceConcurrency() }
        }
    }

    // MARK: - UI

    private func setupUI() {
        let extensionView = ShareExtensionView(
            viewModel: viewModel,
            onDone: { [weak self] in self?.done() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: extensionView)

        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Clipping Pipeline

    private func startClipping() {
        clippingTask = Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await self.performClipping()

                guard !Task.isCancelled else { return }
                self.viewModel.state = .success(result)

                // Auto-dismiss after a short delay
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self.done()
            } catch {
                guard !Task.isCancelled else { return }
                self?.viewModel.state = .error(error.localizedDescription)
            }
        }
    }

    private func performClipping() async throws -> String {
        let settings = ClipperSettings()
        let saveConfig = FileSaver.SaveConfig(from: settings)

        // 1. Extract web content from the share extension input
        viewModel.state = .loading("Extracting content…")

        guard let context = extensionContext,
              let rawContent = await WebContentExtractor.extract(from: context) else {
            throw ClipError.noContent
        }

        try Task.checkCancellation()

        let isImageOnly = rawContent.html == nil && rawContent.url == nil && !rawContent.sharedImages.isEmpty

        // 2. Inject image markers into HTML, run Readability, convert to Markdown
        var articleTitle = rawContent.title
        var markdownBody: String
        var markerMap: [Int: URL] = [:]

        if isImageOnly {
            // Image-only share: OCR the images, skip HTML pipeline
            viewModel.state = .loading("Processing images…")
            markdownBody = ""
        } else if let html = rawContent.html {
            // Use a `do` block so the large intermediate HTML string
            // (markedHTML) is released before image processing.
            do {
                // Replace <img> tags with [[IMG:N]] markers before any processing.
                let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: rawContent.url)
                markerMap = markerResult.markerMap
                let markedHTML = markerResult.html

                try Task.checkCancellation()

                viewModel.state = .loading("Extracting article…")
                let readabilityResult = ReadabilityExtractor.extract(html: markedHTML, url: rawContent.url)

                if let result = readabilityResult {
                    // Convert to markdown directly from the DOM subtree — avoids a
                    // redundant re-parse of the serialized article HTML. Check if
                    // it has meaningful content; the 100-char threshold catches
                    // cases where Readability picked a too-narrow container
                    // (e.g. just the header/title area).
                    let candidateMarkdown = HTMLToMarkdown.convert(node: result.articleNode)
                    if candidateMarkdown.filter({ !$0.isWhitespace }).count >= 100 {
                        markdownBody = candidateMarkdown
                        if let extractedTitle = result.title, !extractedTitle.isEmpty {
                            articleTitle = extractedTitle
                        }
                    } else {
                        markdownBody = HTMLToMarkdown.convert(markedHTML)
                    }
                } else {
                    markdownBody = HTMLToMarkdown.convert(markedHTML)
                }

                try Task.checkCancellation()
            }
        } else if let plain = rawContent.plainText {
            viewModel.state = .loading("Saving text…")
            markdownBody = plain
        } else {
            markdownBody = ""
        }

        try Task.checkCancellation()

        // 3. Process images
        var images: [ExtractedImage] = []
        let prefix = Self.shortHash(title: rawContent.title, url: rawContent.url)

        if isImageOnly {
            viewModel.state = .loading("Running OCR…")
            let processor = ImageProcessor()
            self.imageProcessor = processor
            images = await processor.processSharedImages(
                rawContent.sharedImages,
                enableOCR: settings.enableOCR,
                prefix: prefix
            )
        } else if settings.saveImages, rawContent.html != nil {
            viewModel.state = .loading("Processing images…")

            // Only download images whose markers survived Readability's article
            // extraction. Without this filter, the 20-image cap is consumed by
            // page chrome (logos, badges, recirc thumbnails) before the actual
            // article images get a slot, and downloaded-but-unplaced images
            // dump into the `## Images` / `## Extracted Text (OCR)` fallbacks.
            let surviving = HTMLToMarkdown.findMarkerIndices(in: markdownBody)
            let filteredMarkerMap = markerMap.filter { surviving.contains($0.key) }
            let limitedURLs = Array(filteredMarkerMap.values.prefix(20))

            let processor = ImageProcessor()
            self.imageProcessor = processor
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)

            var urlToPath: [String: String] = [:]
            for image in images {
                urlToPath[image.sourceURL.absoluteString] = "images/\(image.filename)"
            }

            var markerToPath: [Int: String] = [:]
            for (index, url) in filteredMarkerMap {
                if let path = urlToPath[url.absoluteString] {
                    markerToPath[index] = path
                }
            }
            let inlineResult = HTMLToMarkdown.replaceMarkersWithImages(markdownBody, markerToPath: markerToPath)
            markdownBody = inlineResult.markdown
        }

        try Task.checkCancellation()

        // 4. Build the ClipResult
        let clipResult = ClipResult(
            title: articleTitle,
            sourceURL: rawContent.url,
            markdownBody: markdownBody,
            images: images,
            clippedDate: Date()
        )

        // 5. Save to the vault
        viewModel.state = .loading("Saving to vault…")

        try FileSaver.save(clipResult, config: saveConfig)

        // Clean up scratch temp files once the vault move is complete.
        await imageProcessor?.cleanup()
        imageProcessor = nil

        return rawContent.title
    }

    // MARK: - Completion

    private func done() {
        guard trySetComplete() else { return }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        guard trySetComplete() else { return }
        clippingTask?.cancel()
        clippingTask = nil
        // Fire-and-forget scratch directory cleanup; fine for the extension to
        // tear down while this runs since the actor method is short and the
        // temp files live under NSTemporaryDirectory() either way.
        if let processor = imageProcessor {
            imageProcessor = nil
            Task { await processor.cleanup() }
        }
        extensionContext?.cancelRequest(withError: ClipError.cancelled)
    }

    /// Atomically checks and sets `didComplete`. Returns `true` if this call
    /// was the first to set it (i.e., the caller should proceed with completion).
    private func trySetComplete() -> Bool {
        didCompleteLock.lock()
        defer { didCompleteLock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }

    /// Short hex hash identifying a single clip, used as an image filename prefix
    /// so two clips with the same inferred indices do not overwrite each other.
    private static func shortHash(title: String, url: URL?) -> String {
        let seed = "\(title)|\(url?.absoluteString ?? "")|\(Date().timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum ClipError: LocalizedError {
    case noContent
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "Could not extract content from the shared item. Try sharing a URL, text, or image."
        case .cancelled:
            return "Clipping was cancelled."
        }
    }
}
