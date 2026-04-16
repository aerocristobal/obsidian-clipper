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
}
