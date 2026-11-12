import Foundation
import Testing

@testable import NXPlayKit

/// Free Up Space's Metal leftovers: the `gpuarchiver-*` folders games' pipeline capture leaves in the user cache
/// folder, of which only those untouched for a day go, and none while a game runs.
@MainActor @Suite final class MetalLeftoversTests {
    let parent = FileManager.default.temporaryDirectory.appending(
        path: "nxplay-gpuarchiver-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: parent) }

    init() throws {
        try folder("gpuarchiver-old1", age: 3 * 86_400, size: 4096)
        try folder("gpuarchiver-old2", age: 2 * 86_400, size: 8192)
        try folder("gpuarchiver-new", age: 600, size: 4096)  // a run of today's, perhaps still going
        // not Metal's serializer folders
        try FileManager.default.createDirectory(
            at: parent.appending(path: "other-old"), withIntermediateDirectories: true)
        try touch(parent.appending(path: "other-old"), age: 5 * 86_400)
    }

    @Test func onlyFoldersUntouchedForADayAreFinished() {
        #expect(MetalLeftovers.finished(in: parent).map(\.lastPathComponent).sorted() == [
            "gpuarchiver-old1", "gpuarchiver-old2",
        ])
        #expect(MetalLeftovers.size(in: parent) >= 12_288)
        #expect(MetalLeftovers.file(in: parent.appending(path: "none"), gameRunning: false) == nil)
    }

    @Test func listedApartAndDeletedWithoutTheRecentOnes() async throws {
        let cleanup = Cleanup(cache: nil, metalState: parent)
        await cleanup.scan(games: [], busy: [])
        let file = try #require(cleanup.extras.first)
        #expect(file.kind == .metalState && file.blocked == nil)
        for _ in 0..<100 where cleanup.isMeasuring { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cleanup.size(.metalState) >= 12_288 && cleanup.totalSize == cleanup.size(.metalState))

        cleanup.toggle(.metalState)
        cleanup.confirmation = Cleanup.phrase
        await cleanup.delete()
        let left = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        #expect(left == ["gpuarchiver-new", "other-old"])
        await cleanup.scan(games: [], busy: [])
        #expect(cleanup.extras.isEmpty)
    }

    @Test func aRunningGameKeepsThem() async throws {
        let cleanup = Cleanup(cache: nil, metalState: parent)
        await cleanup.scan(games: [], busy: [UUID().uuidString])
        #expect(try #require(cleanup.extras.first).blocked != nil)
    }

    private func folder(_ name: String, age: TimeInterval, size: Int) throws {
        let url = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let state = url.appending(path: "PersistentState")
        try Data(count: size).write(to: state)
        try touch(state, age: age)
        try touch(url, age: age)
    }

    private func touch(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date.now - age], ofItemAtPath: url.path)
    }
}
