import Foundation
import UIKit
import Vision

/// Downloads images from URLs and performs OCR using Apple's Vision framework.
actor ImageProcessor {

    /// Concurrent in-flight downloads+OCR. Share extensions have a ~50MB RAM
    /// budget and Vision `.accurate` allocates 2–5MB per image; keep this low.
    private static let maxConcurrent = 3

    /// Longest edge (in pixels) before downscaling prior to OCR.
    private static let maxOCRDimension: CGFloat = 2048

    /// URLSession configured with a 15-second resource timeout for image downloads.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Download images from the given URLs and optionally run OCR on each.
    /// `prefix` becomes part of each saved filename to avoid collisions across clips.
    func process(urls: [URL], enableOCR: Bool, prefix: String) async -> [ExtractedImage] {
        await withTaskGroup(of: ExtractedImage?.self) { group in
            var iterator = urls.enumerated().makeIterator()

            // Seed the group up to the concurrency cap.
            for _ in 0..<Self.maxConcurrent {
                guard let (index, url) = iterator.next() else { break }
                group.addTask {
                    await self.downloadAndProcess(url: url, index: index, prefix: prefix, enableOCR: enableOCR)
                }
            }

            // Drain results and refill as slots free up.
            var results: [ExtractedImage] = []
            while let result = await group.next() {
                if let image = result {
                    results.append(image)
                }
                if let (index, url) = iterator.next() {
                    group.addTask {
                        await self.downloadAndProcess(url: url, index: index, prefix: prefix, enableOCR: enableOCR)
                    }
                }
            }
            return results.sorted { $0.filename < $1.filename }
        }
    }

    private func downloadAndProcess(url: URL, index: Int, prefix: String, enableOCR: Bool) async -> ExtractedImage? {
        // Download the image data
        guard let (data, response) = try? await Self.session.data(from: url) else {
            return nil
        }

        // Verify it's actually an image. Accept either an image/* MIME type or
        // data that UIImage can decode.
        let mimeType = (response as? HTTPURLResponse)?.mimeType
        let isImageMime = mimeType?.hasPrefix("image/") ?? false
        if !isImageMime && UIImage(data: data) == nil {
            return nil
        }

        // Determine file extension and filename (prefixed to avoid collisions).
        let ext = fileExtension(for: url, mimeType: (response as? HTTPURLResponse)?.mimeType)
        let filename = "\(prefix)-\(index + 1).\(ext)"

        var extracted = ExtractedImage(
            sourceURL: url,
            data: data,
            filename: filename,
            ocrText: nil
        )

        // Run OCR if enabled. Downscale first to keep Vision allocations in check.
        if enableOCR, let uiImage = UIImage(data: data) {
            let ocrImage = Self.downscaledCGImage(from: uiImage)
            if let cg = ocrImage {
                extracted.ocrText = await recognizeText(in: cg)
            }
        }

        return extracted
    }

    /// Downscale a `UIImage` so its longest edge is at most `maxOCRDimension`,
    /// returning a `CGImage` suitable for Vision. Returns the original CGImage
    /// if it is already small enough.
    private static func downscaledCGImage(from image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxOCRDimension else { return cg }

        let scale = maxOCRDimension / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.cgImage
    }

    /// Perform OCR on a CGImage using VNRecognizeTextRequest.
    private func recognizeText(in image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text.isEmpty ? nil : text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func fileExtension(for url: URL, mimeType: String?) -> String {
        // Try MIME type first
        if let mime = mimeType {
            switch mime {
            case "image/png": return "png"
            case "image/jpeg", "image/jpg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            default: break
            }
        }

        // Fall back to URL path extension
        let pathExt = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(pathExt) {
            return pathExt == "jpeg" ? "jpg" : pathExt
        }

        return "png" // Safe default
    }
}
