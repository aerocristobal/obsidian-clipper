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

        // 2. Inject image markers into HTML, run Readability, convert to Markdown
        var articleTitle = rawContent.title
        var markdownBody: String
        var markerMap: [Int: URL] = [:]

        if isImageOnly {
            // Image-only share: OCR the images, skip HTML pipeline
            viewModel.state = .loading("Processing images…")
            markdownBody = ""
        } else if let html = rawContent.html {
            // Replace <img> tags with [[IMG:N]] markers before any processing.
            // Markers survive Readability extraction and NSAttributedString conversion.
            let markerResult = HTMLToMarkdown.replaceImgTagsWithMarkers(html, baseURL: rawContent.url)
            markerMap = markerResult.markerMap
            let markedHTML = markerResult.html

            viewModel.state = .loading("Extracting article…")
            let readabilityResult = ReadabilityExtractor.extract(html: markedHTML, url: rawContent.url)

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
                // Fall back to full marked HTML
                articleHTML = markedHTML
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
            // Web page images — download from marker map URLs (already filtered/deduped)
            // plus any additional URLs found via extractImageURLs that weren't in <img> tags
            viewModel.state = .loading("Processing images…")

            // Collect URLs from marker map
            var imageURLs = Array(markerMap.values)
            let markerURLStrings = Set(imageURLs.map { $0.absoluteString })

            // Also extract URLs from the original HTML for images that may not have
            // been in <img> tags (e.g., CSS backgrounds, <source> elements)
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

            // Limit to first 20 images to avoid huge downloads
            let limitedURLs = Array(imageURLs.prefix(20))

            let processor = ImageProcessor()
            images = await processor.process(urls: limitedURLs, enableOCR: settings.enableOCR, prefix: prefix)

            // Build URL → local path mapping and replace markers in markdown
            var urlToPath: [String: String] = [:]
            for image in images {
                urlToPath[image.sourceURL.absoluteString] = "images/\(image.filename)"
            }

            // Replace [[IMG:N]] markers with inline image references
            var markerToPath: [Int: String] = [:]
            for (index, url) in markerMap {
                if let path = urlToPath[url.absoluteString] {
                    markerToPath[index] = path
                }
            }
            let inlineResult = HTMLToMarkdown.replaceMarkersWithImages(markdownBody, markerToPath: markerToPath)
            markdownBody = inlineResult.markdown
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
