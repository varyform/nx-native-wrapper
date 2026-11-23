import Foundation
import Testing

@testable import NXPlayKit

/// Free Up Space's storage bars: what each kind takes on each volume its files are on.
@Suite struct CleanupVolumeTests {
    static let games = CleanupVolume.Info(id: "/Volumes/Games", name: "Games", total: 4000, available: 1000)
    static let mac = CleanupVolume.Info(id: "/", name: "Macintosh HD", total: 1000, available: 400)

    static func file(_ path: String, _ size: Int64, _ role: CleanupFile.Role) -> CleanupFile {
        CleanupFile(url: URL(filePath: path), size: size, role: role, blocked: nil)
    }

    @Test func eachVolumeSumsItsKindsTheOneWithMostToRemoveFirst() {
        let files = [
            Self.file("/Volumes/Games/A/a.nsp", 500, .original),
            Self.file("/Volumes/Games/A/a.nsz.nsp", 100, .converted),
            Self.file("/Volumes/Games/A/0100_build", 700, .build),
            Self.file("/Users/me/Library/Developer/x", 50, .xcodeBuild),
            Self.file("/Volumes/Games/B/0200_build", 0, .build),  // still measuring
            Self.file("/gone", 10, .ipa),
        ]
        let volumes = Cleanup.volumes(of: files) { url in
            url.path.hasPrefix("/Volumes/Games") ? Self.games : url.path == "/gone" ? nil : Self.mac
        }
        #expect(volumes.map(\.info.name) == ["Games", "Macintosh HD"])
        #expect(volumes[0].kinds.map(\.kind) == [.gameFiles, .builds])
        #expect(volumes[0].kinds.map(\.size) == [600, 700])
        #expect(volumes[0].used == 3000 && volumes[0].other == 1700)
        #expect(volumes[1].kinds.map(\.kind) == [.xcodeBuilds] && volumes[1].other == 550)
    }

    /// Sizes measured on disk can come to more than a volume reports used (clones, purgeable space): no less than 0.
    @Test func everythingElseIsNeverBelowZero() {
        let volumes = Cleanup.volumes(of: [Self.file("/a", 900, .build)]) { _ in Self.mac }
        #expect(volumes.first?.other == 0)
    }

    /// The games folders' drives have a bar before the scan has found anything on them.
    @Test func aGamesFolderDriveHasABarBeforeTheScan() {
        let volumes = Cleanup.volumes(of: [], also: [URL(filePath: "/Volumes/Games/Switch")]) { _ in Self.games }
        #expect(volumes.map(\.info.name) == ["Games"] && volumes[0].kinds.isEmpty && volumes[0].other == 3000)
    }

    /// The games folders' drive and the Mac's keep their places as sizes come in, whichever has more to remove.
    @Test func theFoldersDrivesKeepTheirOrder() {
        let files = [Self.file("/Users/me/Library/Developer/x", 900, .xcodeBuild), Self.file("/Volumes/Games/a", 1, .ipa)]
        let volumes = Cleanup.volumes(
            of: files, also: [URL(filePath: "/Volumes/Games"), URL(filePath: "/Users/me")]
        ) { url in url.path.hasPrefix("/Volumes/Games") ? Self.games : Self.mac }
        #expect(volumes.map(\.info.name) == ["Games", "Macintosh HD"])
    }
}
