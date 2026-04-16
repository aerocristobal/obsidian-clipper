import XCTest
@testable import ClipperExtension

final class ImageProcessorTests: XCTestCase {

    // MARK: - imageExtension(from:)

    func testImageExtensionPNG() {
        let data = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0), count: 10))
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "png")
    }

    func testImageExtensionJPEG() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(0), count: 10))
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "jpg")
    }

    func testImageExtensionGIF() {
        let data = Data([0x47, 0x49, 0x46, 0x38] + Array(repeating: UInt8(0), count: 10))
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "gif")
    }

    func testImageExtensionWebP() {
        let data = Data([0x52, 0x49, 0x46, 0x46] + Array(repeating: UInt8(0), count: 10))
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "webp")
    }

    func testImageExtensionShortData() {
        let data = Data([0x01, 0x02])
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "png") // default
    }

    func testImageExtensionEmptyData() {
        let data = Data()
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "png") // default
    }

    func testImageExtensionUnknownBytes() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageProcessor.imageExtension(from: data), "png") // default
    }

    // MARK: - fileExtension(for:mimeType:)

    func testFileExtensionMIMETypeWins() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/image.png")!
        let ext = await processor.fileExtension(for: url, mimeType: "image/jpeg")
        XCTAssertEqual(ext, "jpg")
    }

    func testFileExtensionURLFallback() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/image.webp")!
        let ext = await processor.fileExtension(for: url, mimeType: nil)
        XCTAssertEqual(ext, "webp")
    }

    func testFileExtensionJPEGNormalized() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/image.jpeg")!
        let ext = await processor.fileExtension(for: url, mimeType: nil)
        XCTAssertEqual(ext, "jpg")
    }

    func testFileExtensionDefaultPNG() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/image")!
        let ext = await processor.fileExtension(for: url, mimeType: nil)
        XCTAssertEqual(ext, "png")
    }

    func testFileExtensionGIFMime() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/anim")!
        let ext = await processor.fileExtension(for: url, mimeType: "image/gif")
        XCTAssertEqual(ext, "gif")
    }

    func testFileExtensionWebPMime() async {
        let processor = ImageProcessor()
        let url = URL(string: "https://example.com/photo")!
        let ext = await processor.fileExtension(for: url, mimeType: "image/webp")
        XCTAssertEqual(ext, "webp")
    }

    // MARK: - isFetchableScheme(_:)

    func testIsFetchableSchemeHTTP() {
        XCTAssertTrue(ImageProcessor.isFetchableScheme(URL(string: "http://example.com/a.png")!))
    }

    func testIsFetchableSchemeHTTPS() {
        XCTAssertTrue(ImageProcessor.isFetchableScheme(URL(string: "https://example.com/a.png")!))
    }

    func testIsFetchableSchemeUppercaseAccepted() {
        XCTAssertTrue(ImageProcessor.isFetchableScheme(URL(string: "HTTPS://example.com/a.png")!))
    }

    func testIsFetchableSchemeFileRejected() {
        XCTAssertFalse(ImageProcessor.isFetchableScheme(URL(string: "file:///etc/passwd")!))
    }

    func testIsFetchableSchemeJavascriptRejected() {
        XCTAssertFalse(ImageProcessor.isFetchableScheme(URL(string: "javascript:alert(1)")!))
    }

    func testIsFetchableSchemeFTPRejected() {
        XCTAssertFalse(ImageProcessor.isFetchableScheme(URL(string: "ftp://example.com/a.png")!))
    }

    func testIsFetchableSchemeDataRejected() {
        XCTAssertFalse(ImageProcessor.isFetchableScheme(URL(string: "data:image/png;base64,AAAA")!))
    }

    // MARK: - shouldAcceptImageSize(_:)

    func testShouldAcceptImageSizeWithinCap() async {
        ImageProcessor.testMaxCumulativeImageBytesOverride = 100 * 1024 // 100 KB
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        let accepted = await processor.shouldAcceptImageSize(50 * 1024)
        XCTAssertTrue(accepted)
    }

    func testShouldAcceptImageSizeRejectsSingleOversized() async {
        ImageProcessor.testMaxCumulativeImageBytesOverride = 100 * 1024 // 100 KB
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        // A single image larger than the whole cap is rejected outright.
        let accepted = await processor.shouldAcceptImageSize(200 * 1024)
        XCTAssertFalse(accepted)
    }

    func testShouldAcceptImageSizeRejectsAtBoundary() async {
        ImageProcessor.testMaxCumulativeImageBytesOverride = 100 * 1024
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        let atCap = await processor.shouldAcceptImageSize(100 * 1024)
        XCTAssertTrue(atCap)
        let justOver = await processor.shouldAcceptImageSize(100 * 1024 + 1)
        XCTAssertFalse(justOver)
    }

    func testSharedImagesRespectCumulativeCap() async {
        // 30KB cap, four 10KB shared images — first three accepted, fourth skipped.
        ImageProcessor.testMaxCumulativeImageBytesOverride = 30 * 1024
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        let blob = makeDummyPNG(sizeBytes: 10 * 1024)
        let images = [blob, blob, blob, blob]
        let results = await processor.processSharedImages(images, enableOCR: false, prefix: "test")
        // Three fit within 30KB; fourth is rejected by cap.
        XCTAssertEqual(results.count, 3)
    }

    func testSharedImagesOversizedSingleDoesNotBlockOthers() async {
        // Cap 20KB. First image is 50KB (oversized, skipped), next two 5KB each (accepted).
        ImageProcessor.testMaxCumulativeImageBytesOverride = 20 * 1024
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        let huge = makeDummyPNG(sizeBytes: 50 * 1024)
        let small = makeDummyPNG(sizeBytes: 5 * 1024)
        let results = await processor.processSharedImages([huge, small, small], enableOCR: false, prefix: "test")
        XCTAssertEqual(results.count, 2)
    }

    func testProcessResetsCumulativeTotalBetweenCalls() async {
        ImageProcessor.testMaxCumulativeImageBytesOverride = 30 * 1024
        defer { ImageProcessor.testMaxCumulativeImageBytesOverride = nil }

        let processor = ImageProcessor()
        let blob = makeDummyPNG(sizeBytes: 10 * 1024)

        let first = await processor.processSharedImages([blob, blob, blob], enableOCR: false, prefix: "a")
        XCTAssertEqual(first.count, 3)

        // Second call should reset the counter and accept another 3.
        let second = await processor.processSharedImages([blob, blob, blob], enableOCR: false, prefix: "b")
        XCTAssertEqual(second.count, 3)
    }

    // MARK: - Streaming / scratch directory lifecycle

    func testSharedImageWritesBytesToTempFile() async {
        let processor = ImageProcessor()
        let blob = makeDummyPNG(sizeBytes: 4 * 1024)
        let results = await processor.processSharedImages([blob], enableOCR: false, prefix: "stream")

        XCTAssertEqual(results.count, 1)
        guard let image = results.first else { return }

        // The temp file must exist and contain exactly the bytes we handed in.
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.tempFileURL.path),
                      "Scratch temp file should exist after processing")
        let onDisk = try? Data(contentsOf: image.tempFileURL)
        XCTAssertEqual(onDisk, blob, "Temp file bytes should match the input Data exactly")

        await processor.cleanup()
    }

    func testScratchFilesCleanedUpOnCancel() async {
        let processor = ImageProcessor()
        let scratchDir = await processor.scratchDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratchDir.path),
                      "Scratch directory should be created by init()")

        // Run one processing pass so there is at least one temp file to clean up.
        let blob = makeDummyPNG(sizeBytes: 2 * 1024)
        _ = await processor.processSharedImages([blob, blob], enableOCR: false, prefix: "cancel")

        // Confirm scratch is non-empty.
        let contentsBefore = (try? FileManager.default.contentsOfDirectory(atPath: scratchDir.path)) ?? []
        XCTAssertFalse(contentsBefore.isEmpty, "Scratch should contain at least one temp file before cleanup")

        // Simulate the cancel path tearing the processor down.
        await processor.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path),
                       "cleanup() must remove the scratch directory entirely")
    }

    func testCleanupIsIdempotent() async {
        let processor = ImageProcessor()
        let scratchDir = await processor.scratchDirectory
        await processor.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDir.path))
        // A second cleanup on an already-removed directory must not throw.
        await processor.cleanup()
    }

    // MARK: - Test helpers

    /// Build a decodable PNG whose encoded size is approximately `sizeBytes`. The
    /// image must be real enough for `UIImage(data:)` to decode it, otherwise
    /// `processSharedImage` filters it out before the cap check has any effect.
    private func makeDummyPNG(sizeBytes: Int) -> Data {
        // Render a solid-color image; PNG compression will shrink it drastically.
        // Pad with trailing zero bytes after the PNG end chunk — UIImage still decodes
        // the leading PNG and the total Data length hits our target.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var png = img.pngData() ?? Data()
        if png.count < sizeBytes {
            png.append(Data(count: sizeBytes - png.count))
        }
        return png
    }
}
