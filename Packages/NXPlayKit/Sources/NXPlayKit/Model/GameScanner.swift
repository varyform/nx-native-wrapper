import Foundation

/// Finds the games in a folder laid out the way build_ipa_from_nsp.py leaves it:
/// `<root>/<game>/*.nsp` and `<root>/<game>/<title ID>_build/extract/v<version>/{icon.jpg,control.nacp}`.
public enum GameScanner {
    static let packageExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]
    static let launcherName = "start_mac.sh"
    /// nxplay's mark of a kept build (Keep This Build).
    static let keepName = "keep"

    public static func scan(root: URL) -> [Game] {
        children(of: root)
            .compactMap(game(at:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func game(at folder: URL) -> Game? {
        guard isDirectory(folder) else { return nil }
        let entries = children(of: folder)
        let packages = entries.filter { packageExtensions.contains($0.pathExtension.lowercased()) }
        let hasPackages = !packages.isEmpty
        let builds = entries.filter(isBuildFolder).map(Build.init(folder:))
        // a build with nothing but its run folder holds the saves of a removed game (Remove Game keeps them): no game
        // until its files come back
        guard hasPackages || builds.contains(where: \.hasContent) else { return nil }

        // A derived profile can leave a second build folder: take the most finished one, then the newest
        let build = builds.max { ($0.rank, $0.modified) < ($1.rank, $1.modified) }
        let nacp = build?.nacpURL.flatMap(NACP.init(contentsOf:))
        let state: Game.State =
            build?.isReady == true ? .ready : build?.extract != nil ? .extracted : .notExtracted

        return Game(
            folder: folder,
            name: nacp?.title ?? folder.lastPathComponent,
            titleID: build.map { String($0.folder.lastPathComponent.dropLast("_build".count)) },
            version: nacp?.displayVersion,
            languages: nacp?.languages ?? [],
            iconURL: build?.iconURL,
            buildFolder: build?.folder,
            ipaURL: newest(entries.filter { $0.pathExtension.lowercased() == "ipa" }),
            xcodeBuildFolder: build.map {
                $0.folder.appending(path: "xcode-derived-data", directoryHint: .isDirectory)
            }
            .flatMap { isDirectory($0) ? $0 : nil },
            // nxnative's app: <game name>.app with its Mac host inside (not any app that happens to be there)
            macAppURL: newest(
                entries.filter {
                    $0.pathExtension == "app"
                        && FileManager.default.isExecutableFile(
                            atPath: $0.appending(path: "Contents/MacOS/dmhost").path)
                }),
            hasPackages: hasPackages,
            // a copied folder carries the mark on itself, a copied file on itself
            isCopying: isBeingCopied(folder) || packages.contains(where: isBeingCopied),
            lastPlayed: build.flatMap {
                try? $0.folder.appending(path: "run/last_played")
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            },
            isKept: build.map {
                FileManager.default.fileExists(atPath: $0.folder.appending(path: keepName).path)
            } ?? false,
            state: state
        )
    }

    /// Finder dates what it is still copying 24 January 1984 (the Mac's launch day) and puts the source's
    /// creation date back when the copy is complete; nothing real is that old. Only the item dragged gets the
    /// mark: a copied game folder carries it while the files inside have today's date, a copied file carries it
    /// itself. A day either side covers the time zone. Other copies leave no such mark: browsers and torrent
    /// clients use another extension until a file is complete, rsync a hidden name, and cp nothing at all.
    static func isBeingCopied(_ url: URL) -> Bool {
        guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        else { return false }
        return abs(created.timeIntervalSince(finderCopyDate)) < 86_400
    }

    static let finderCopyDate = Date(timeIntervalSince1970: 443_750_400)  // 1984-01-24 00:00 UTC

    struct Build {
        let folder: URL
        /// The newest `extract/v<version>` (the version the build packs).
        let extract: URL?
        let iconURL: URL?
        let nacpURL: URL?
        let isReady: Bool
        let modified: Date
        /// More than the run folder (saves and caches): something extracted or built.
        let hasContent: Bool

        var rank: Int { isReady ? 2 : extract != nil ? 1 : 0 }

        init(folder: URL) {
            let fm = FileManager.default
            let versions = GameScanner.extractVersions(in: folder)
            func first(_ name: String) -> URL? {
                versions.lazy.map { $0.appending(path: name) }.first {
                    fm.fileExists(atPath: $0.path)
                }
            }
            self.folder = folder
            extract = versions.first
            iconURL = first("icon.jpg")
            nacpURL = first("control.nacp")
            // the same check nxplay makes before it reuses a launcher
            isReady =
                fm.fileExists(atPath: folder.appending(path: GameScanner.launcherName).path)
                && fm.isExecutableFile(atPath: folder.appending(path: "tools/dmhost").path)
            modified =
                (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            hasContent = GameScanner.children(of: folder).contains { $0.lastPathComponent != "run" }
        }
    }

    /// `extract/v<number>` folders, newest version first.
    static func extractVersions(in build: URL) -> [URL] {
        children(of: build.appending(path: "extract", directoryHint: .isDirectory))
            .compactMap { url -> (Int, URL)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("v"), let version = Int(name.dropFirst()), isDirectory(url)
                else { return nil }
                return (version, url)
            }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    static func newest(_ files: [URL]) -> URL? {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return files.max { modified($0) < modified($1) }
    }

    static func isBuildFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix("_build") else { return false }
        let id = name.dropLast("_build".count)
        return id.count == 16 && id.allSatisfy(\.isHexDigit) && isDirectory(url)
    }

    static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
