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
                if Task.isCancelled { break }
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

    /// Process images shared directly (e.g. from Photos, Screenshots) — no download needed.
    /// Runs OCR if enabled and returns ExtractedImage results.
    /// Uses the same concurrency cap as `process()` to stay within the extension memory budget.
    func processSharedImages(_ imageDataList: [Data], enableOCR: Bool, prefix: String) async -> [ExtractedImage] {
        // Limit to 10 shared images to stay within the 50MB extension budget
        let limited = Array(imageDataList.prefix(10))

        return await withTaskGroup(of: ExtractedImage?.self) { group in
            var iterator = limited.enumerated().makeIterator()

            // Seed the group up to the concurrency cap.
            for _ in 0..<Self.maxConcurrent {
                guard let (index, data) = iterator.next() else { break }
                group.addTask {
                    await self.processSharedImage(data: data, index: index, prefix: prefix, enableOCR: enableOCR)
                }
            }

            // Drain results and refill as slots free up.
            var results: [ExtractedImage] = []
            while let result = await group.next() {
                if let image = result {
                    results.append(image)
                }
                if let (index, data) = iterator.next() {
                    group.addTask {
                        await self.processSharedImage(data: data, index: index, prefix: prefix, enableOCR: enableOCR)
                    }
                }
            }
            return results.sorted { $0.filename < $1.filename }
        }
    }

    private func processSharedImage(data: Data, index: Int, prefix: String, enableOCR: Bool) async -> ExtractedImage? {
        guard !Task.isCancelled else { return nil }

        // Validate the data is a decodable image and optionally get a downscaled
        // CGImage for OCR. Use autoreleasepool so UIImage intermediates are freed.
        var isValid = false
        let cgForOCR: CGImage? = autoreleasepool {
            guard let uiImage = UIImage(data: data) else { return nil }
            isValid = true
            guard enableOCR else { return nil }
            return Self.downscaledCGImage(from: uiImage)
        }

        guard isValid else { return nil }

        let ocrText: String?
        if let cg = cgForOCR {
            ocrText = await recognizeText(in: cg)
        } else {
            ocrText = nil
        }

        let ext = Self.imageExtension(from: data)
        let filename = "\(prefix)-\(index + 1).\(ext)"
        let sourceURL = URL(string: "shared-image://\(filename)")!

        return ExtractedImage(
            sourceURL: sourceURL,
            data: data,
            filename: filename,
            ocrText: ocrText
        )
    }

    /// Determine image format from data header bytes.
    static func imageExtension(from data: Data) -> String {
        guard data.count >= 4 else { return "png" }
        let bytes = [UInt8](data.prefix(4))
        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        // GIF: 47 49 46
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "gif"
        }
        // WebP: starts with RIFF...WEBP
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "webp"
        }
        return "png"
    }

    private func downloadAndProcess(url: URL, index: Int, prefix: String, enableOCR: Bool) async -> ExtractedImage? {
        guard !Task.isCancelled else { return nil }

        // Download the image data
        guard let (data, response) = try? await Self.session.data(from: url) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        // Verify it's actually an image. Accept either an image/* MIME type or
        // data that UIImage can decode. Use autoreleasepool for the UIImage probe.
        let mimeType = (response as? HTTPURLResponse)?.mimeType
        let isImageMime = mimeType?.hasPrefix("image/") ?? false
        if !isImageMime {
            let valid = autoreleasepool { UIImage(data: data) != nil }
            guard valid else { return nil }
        }

        // Determine file extension and filename (prefixed to avoid collisions).
        let ext = fileExtension(for: url, mimeType: (response as? HTTPURLResponse)?.mimeType)
        let filename = "\(prefix)-\(index + 1).\(ext)"

        // Run OCR if enabled. Downscale inside autoreleasepool to release UIImage promptly.
        let ocrText: String?
        if enableOCR {
            let cgForOCR: CGImage? = autoreleasepool {
                guard let uiImage = UIImage(data: data) else { return nil }
                return Self.downscaledCGImage(from: uiImage)
            }
            if let cg = cgForOCR {
                ocrText = await recognizeText(in: cg)
            } else {
                ocrText = nil
            }
        } else {
            ocrText = nil
        }

        return ExtractedImage(
            sourceURL: url,
            data: data,
            filename: filename,
            ocrText: ocrText
        )
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
            try? handler.perform([request])
        }
    }

    func fileExtension(for url: URL, mimeType: String?) -> String {
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
