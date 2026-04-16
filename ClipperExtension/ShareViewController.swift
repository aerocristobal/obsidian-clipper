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
class ShareViewController: UIViewController {

    private let viewModel = ShareViewModel()
    /// Guards against double-completion of the extension context.
    /// Accessed from both the main-actor Task and UI callbacks, so
    /// we protect it with an os_unfair_lock for thread safety.
    private var didComplete = false
    private let didCompleteLock = NSLock()
    /// Handle to the clipping Task so we can cancel it when the user taps Cancel.
    private var clippingTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startClipping()
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
            // Use a `do` block so the large intermediate HTML strings
            // (markedHTML, articleHTML) are released before image processing.
            do {
                // Replace <img> tags with [[IMG:N]] markers before any processing.
                let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: rawContent.url)
                markerMap = markerResult.markerMap
                let markedHTML = markerResult.html

                try Task.checkCancellation()

                viewModel.state = .loading("Extracting article…")
                let readabilityResult = ReadabilityExtractor.extract(html: markedHTML, url: rawContent.url)

                let articleHTML: String
                if let result = readabilityResult {
                    // Convert to markdown and check if it has meaningful content.
                    // The 100-char threshold catches cases where Readability picked
                    // a too-narrow container (e.g. just the header/title area).
                    let candidateMarkdown = HTMLToMarkdown.convert(result.articleHTML)
                    if candidateMarkdown.filter({ !$0.isWhitespace }).count >= 100 {
                        articleHTML = result.articleHTML
                        markdownBody = candidateMarkdown
                        if let extractedTitle = result.title, !extractedTitle.isEmpty {
                            articleTitle = extractedTitle
                        }
                    } else {
                        articleHTML = markedHTML
                        markdownBody = HTMLToMarkdown.convert(articleHTML)
                    }
                } else {
                    articleHTML = markedHTML
                    markdownBody = HTMLToMarkdown.convert(articleHTML)
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
            images = await processor.processSharedImages(
                rawContent.sharedImages,
                enableOCR: settings.enableOCR,
                prefix: prefix
            )
        } else if settings.saveImages, let html = rawContent.html {
            viewModel.state = .loading("Processing images…")

            var imageURLs = Array(markerMap.values)
            let markerURLStrings = Set(imageURLs.map { $0.absoluteString })

            let additionalURLs = HTMLToMarkdown.extractImageURLs(from: html, baseURL: rawContent.url)
                .filter { !markerURLStrings.contains($0.absoluteString) }
                .filter { url in
                    let path = url.absoluteString.lowercased()
                    if path.contains("pixel") || path.contains("tracking") || path.contains("beacon") {
                        return false
                    }
                    if path.contains(".svg") { return false }
                    if path.hasPrefix("data:") { return false }
                    return true
                }
            imageURLs.append(contentsOf: additionalURLs)

            let limitedURLs = Array(imageURLs.prefix(20))

            let processor = ImageProcessor()
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)

            var urlToPath: [String: String] = [:]
            for image in images {
                urlToPath[image.sourceURL.absoluteString] = "images/\(image.filename)"
            }

            var markerToPath: [Int: String] = [:]
            for (index, url) in markerMap {
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
