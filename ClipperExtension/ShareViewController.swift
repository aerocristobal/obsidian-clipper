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
    private var didComplete = false

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
        Task {
            do {
                let result = try await performClipping()

                viewModel.state = .success(result)

                // Auto-dismiss after a short delay
                try? await Task.sleep(for: .seconds(1.5))
                done()
            } catch {
                viewModel.state = .error(error.localizedDescription)
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

        let isImageOnly = rawContent.html == nil && rawContent.url == nil && !rawContent.sharedImages.isEmpty

        // 2. Run Readability extraction to isolate article content
        var articleTitle = rawContent.title
        let markdownBody: String

        if isImageOnly {
            // Image-only share: OCR the images, skip HTML pipeline
            viewModel.state = .loading("Processing images…")
            markdownBody = ""
        } else if let html = rawContent.html {
            viewModel.state = .loading("Extracting article…")
            let readabilityResult = ReadabilityExtractor.extract(html: html, url: rawContent.url)

            // Use extracted article HTML for Markdown if it has enough content
            let articleHTML: String
            if let result = readabilityResult,
               result.articleHTML.filter({ !$0.isWhitespace }).count >= 100 {
                articleHTML = result.articleHTML
                // Use the Readability-extracted title if available
                if let extractedTitle = result.title, !extractedTitle.isEmpty {
                    articleTitle = extractedTitle
                }
            } else {
                // Fall back to full HTML
                articleHTML = html
            }

            viewModel.state = .loading("Converting to Markdown…")
            markdownBody = HTMLToMarkdown.convert(articleHTML)
        } else if let plain = rawContent.plainText {
            viewModel.state = .loading("Saving text…")
            markdownBody = plain
        } else {
            markdownBody = ""
        }

        // 3. Process images
        var images: [ExtractedImage] = []
        let prefix = Self.shortHash(title: rawContent.title, url: rawContent.url)

        if isImageOnly {
            // Directly shared images — run OCR on each
            viewModel.state = .loading("Running OCR…")
            let processor = ImageProcessor()
            images = await processor.processSharedImages(
                rawContent.sharedImages,
                enableOCR: settings.enableOCR,
                prefix: prefix
            )
        } else if settings.saveImages, let html = rawContent.html {
            // Web page images — download from extracted URLs
            viewModel.state = .loading("Processing images…")

            let imageURLs = HTMLToMarkdown.extractImageURLs(from: html, baseURL: rawContent.url)

            // Filter: skip tiny tracking pixels, data URIs, SVGs
            let filteredURLs = imageURLs.filter { url in
                let path = url.absoluteString.lowercased()
                if path.contains("pixel") || path.contains("tracking") || path.contains("beacon") {
                    return false
                }
                if path.contains(".svg") { return false }
                if path.hasPrefix("data:") { return false }
                return true
            }

            // Limit to first 20 images to avoid huge downloads
            let limitedURLs = Array(filteredURLs.prefix(20))

            let processor = ImageProcessor()
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)
        }

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
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.cancelRequest(withError: ClipError.cancelled)
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
