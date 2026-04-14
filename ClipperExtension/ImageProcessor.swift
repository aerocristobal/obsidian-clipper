import Foundation
import UIKit
import Vision

/// Downloads images from URLs and performs OCR using Apple's Vision framework.
actor ImageProcessor {

    /// Download images from the given URLs and optionally run OCR on each.
    func process(urls: [URL], enableOCR: Bool) async -> [ExtractedImage] {
        await withTaskGroup(of: ExtractedImage?.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    await self.downloadAndProcess(url: url, index: index, enableOCR: enableOCR)
                }
            }

            var results: [ExtractedImage] = []
            for await result in group {
                if let image = result {
                    results.append(image)
                }
            }
            return results.sorted { $0.filename < $1.filename }
        }
    }

    private func downloadAndProcess(url: URL, index: Int, enableOCR: Bool) async -> ExtractedImage? {
        // Download the image data
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }

        // Verify it's actually an image
        guard let mimeType = (response as? HTTPURLResponse)?.mimeType,
              mimeType.hasPrefix("image/") else {
            // Try to detect from data
            guard UIImage(data: data) != nil else { return nil }
        }

        // Determine file extension
        let ext = fileExtension(for: url, mimeType: (response as? HTTPURLResponse)?.mimeType)
        let filename = "image-\(index + 1).\(ext)"

        var extracted = ExtractedImage(
            sourceURL: url,
            data: data,
            filename: filename,
            ocrText: nil
        )

        // Run OCR if enabled
        if enableOCR, let image = UIImage(data: data)?.cgImage {
            extracted.ocrText = await recognizeText(in: image)
        }

        return extracted
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
