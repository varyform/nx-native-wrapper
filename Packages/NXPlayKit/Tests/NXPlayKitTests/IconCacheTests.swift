import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NXPlayKit

@MainActor @Suite struct IconCacheTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-icons-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) throws -> URL {
        let url = folder.appending(path: name)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let file = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(file, image, nil)
        #expect(CGImageDestinationFinalize(file))
        return url
    }

    @Test func aLargeIconShrinksToTheSizeACardShowsIt() async throws {
        let url = try writeJPEG("big.jpg", width: 1024, height: 1024)
        let image = try #require(await IconCache.loadThumbnail(at: url).image)
        #expect(image.width == IconCache.thumbnailPixels)
        #expect(image.height == IconCache.thumbnailPixels)
    }

    @Test func aWideIconKeepsItsShape() async throws {
        let url = try writeJPEG("wide.jpg", width: 1024, height: 512)
        let image = try #require(await IconCache.loadThumbnail(at: url).image)
        #expect(image.width == IconCache.thumbnailPixels)
        #expect(image.height == IconCache.thumbnailPixels / 2)
    }

    @Test func aSmallIconIsntBlownUp() async throws {
        let url = try writeJPEG("small.jpg", width: 256, height: 256)
        let image = try #require(await IconCache.loadThumbnail(at: url).image)
        #expect(image.width <= 256)
    }

    @Test func aFileThatIsntAnImageHasNoThumbnail() async throws {
        let url = folder.appending(path: "broken.jpg")
        try Data("not a jpeg".utf8).write(to: url)
        #expect(await IconCache.loadThumbnail(at: url).image == nil)
        // the view tells this from an icon still loading
        #expect(IconCache.thumbnail(at: url) != nil)
    }

    @Test func nothingIsCachedBeforeTheFirstLoad() throws {
        let url = try writeJPEG("new.jpg", width: 64, height: 64)
        #expect(IconCache.thumbnail(at: url) == nil)
    }

    @Test func aReplacedFileLoadsAgain() async throws {
        let url = try writeJPEG("art.jpg", width: 1024, height: 1024)
        let first = await IconCache.loadThumbnail(at: url)
        #expect(first.image?.height == IconCache.thumbnailPixels)

        _ = try writeJPEG("art.jpg", width: 1024, height: 512)
        try FileManager.default.setAttributes(
            [.modificationDate: first.modified.addingTimeInterval(60)], ofItemAtPath: url.path)
        // until the load, what's cached still shows, rather than a gap
        #expect(IconCache.thumbnail(at: url)?.image?.height == IconCache.thumbnailPixels)
        let second = await IconCache.loadThumbnail(at: url)
        #expect(second.image?.height == IconCache.thumbnailPixels / 2)
    }

    @Test func anUnchangedFileIsntDecodedAgain() async throws {
        let url = try writeJPEG("same.jpg", width: 512, height: 512)
        let first = await IconCache.loadThumbnail(at: url)
        let second = await IconCache.loadThumbnail(at: url)
        #expect(first.image === second.image)
    }

    @Test func loadsOfTheSameIconAtOnceShareOneDecode() async throws {
        let url = try writeJPEG("shared.jpg", width: 512, height: 512)
        async let one = IconCache.loadThumbnail(at: url)
        async let two = IconCache.loadThumbnail(at: url)
        let (first, second) = await (one, two)
        #expect(first.image === second.image)
    }
}
