import Foundation
import Observation

/// What Tools › Free Up Space can delete.
public enum CleanupKind: String, CaseIterable, Identifiable, Sendable {
    /// A game's NSP / NSZ / XCI / XCZ files, and the NSPs a build converted from NSZ (`<id>_build/nsp`).
    case gameFiles
    /// `<id>_build` without its saves, its converted NSPs or its Xcode build: the extracted and built game, which
    /// Play builds again from the game files.
    case builds
    case ipas
    /// `<id>_build/xcode-derived-data`: Install on Device's build, a full copy of the game.
    case xcodeBuilds
    /// `<game name>.app` that Make Mac App packed into the game folder, with nxnative's `<name>.app.key` beside it.
    case macApps

    public var id: String { rawValue }
}

public struct CleanupFile: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case original
        /// An NSP the build decompressed from an NSZ and keeps for the next build.
        case converted
        /// A game's build folder, what `buildContents` lists of it.
        case build
        case ipa
        case xcodeBuild
        case macApp
    }

    public let url: URL
    /// Space on disk (allocated; a folder counts everything in it); 0 while `measuring`.
    public var size: Int64
    /// A folder still being measured: builds and Xcode builds hold hundreds of thousands of files (a shader cache
    /// alone), so the window lists them first and fills their sizes in.
    public var measuring = false
    public let role: Role
    /// Why it cannot be removed now; nil when it can.
    public let blocked: String?
    public var id: URL { url }

    public var kind: CleanupKind {
        switch role {
        case .original, .converted: .gameFiles
        case .build: .builds
        case .ipa: .ipas
        case .xcodeBuild: .xcodeBuilds
        case .macApp: .macApps
        }
    }
}

/// One game's removable files, of every kind.
public struct CleanupGroup: Identifiable, Sendable {
    public let game: Game
    public let files: [CleanupFile]
    public var id: Game.ID { game.id }
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// The state of the Free Up Space window: nothing is selected until the user picks it, and deleting needs
/// the confirmation phrase typed.
@MainActor @Observable
public final class Cleanup {
    public enum Phase: Equatable, Sendable {
        case idle, scanning, deleting
        case done(count: Int, size: Int64)
        case failed(String)
    }

    public static let phrase = "yes, I'm sure"

    public private(set) var groups: [CleanupGroup] = []
    public var selection: Set<URL> = []
    public var confirmation = ""
    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var scans = 0
    @ObservationIgnored private var measuring: Task<Void, Never>?
    /// Sizes kept across launches; none in tests.
    @ObservationIgnored private let cache: SizeCache?

    /// Folders measured at once: walking is mostly waiting on the disk, and more than a few at a time no longer
    /// helps (an external SSD went from 130 s one at a time to under a minute at 4–6).
    static let parallelMeasures = 4

    public convenience init() { self.init(cache: nil) }

    init(cache: SizeCache?) { self.cache = cache }

    /// Files and sizes again from disk; the selection keeps only what can still be removed. Everything is listed
    /// at once; the builds and Xcode builds are measured after, one at a time, a size already known shown meanwhile.
    public func scan(games: [Game], busy: Set<Game.ID>) async {
        scans += 1
        let scan = scans
        let previous = phase
        if groups.isEmpty { phase = .scanning }
        let known = Dictionary(
            files.filter { !$0.measuring }.map { ($0.url, $0.size) },
            uniquingKeysWith: { a, _ in a })
        let listed = await Task.detached {
            CleanupScanner.groups(games: games, busy: busy, measuring: false)
        }.value
        guard scan == scans else { return }  // a newer scan started meanwhile
        apply(
            listed.map { group in
                CleanupGroup(
                    game: group.game,
                    files: group.files.map { file in
                        guard file.measuring, let size = known[file.url] else { return file }
                        var shown = file
                        shown.size = size  // last scan's, until measured again
                        return shown
                    })
            })
        if phase == .scanning { phase = previous == .scanning ? .idle : previous }
        // in the background: a scan returns once everything is listed (Delete rescans before it deletes)
        measuring?.cancel()
        let big = listed.flatMap(\.files).filter(\.measuring)
        let cache = cache
        measuring = Task { [weak self] in
            await withTaskGroup(of: CleanupFile.self) { group in
                var pending = big[...]
                func next() {
                    guard let file = pending.popFirst() else { return }
                    group.addTask { CleanupScanner.measure(file, cache: cache) }
                }
                for _ in 0..<Self.parallelMeasures { next() }
                for await measured in group {
                    guard !Task.isCancelled, let self, scan == self.scans else {
                        group.cancelAll()
                        return
                    }
                    self.replace(measured)
                    next()
                }
            }
        }
    }

    private func replace(_ file: CleanupFile) {
        groups = groups.map { group in
            CleanupGroup(
                game: group.game, files: group.files.map { $0.url == file.url ? file : $0 })
        }
    }

    /// Whether a big folder is still being measured.
    public var isMeasuring: Bool { files.contains(where: \.measuring) }

    func apply(_ groups: [CleanupGroup]) {
        self.groups = groups
        selection.formIntersection(selectable)
    }

    var files: [CleanupFile] { groups.flatMap(\.files) }
    var selectable: Set<URL> { Set(files.filter { $0.blocked == nil }.map(\.url)) }

    public var selectedFiles: [CleanupFile] { files.filter { selection.contains($0.url) } }
    public var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.size } }

    public func files(_ kind: CleanupKind) -> [CleanupFile] { files.filter { $0.kind == kind } }
    public func size(_ kind: CleanupKind) -> Int64 { files(kind).reduce(0) { $0 + $1.size } }

    /// "Yes, I'm sure", "yes im sure", "YES I’M SURE": letters and single spaces compared.
    public var isConfirmed: Bool { Self.normalized(confirmation) == Self.normalized(Self.phrase) }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").joined(
            separator: " ")
    }

    public var canDelete: Bool { !selection.isEmpty && isConfirmed && phase != .deleting }

    /// Why a file can't join the selection as it is: a game's build and its game files never go together, since
    /// without both nothing could play or build it again. Converted NSPs can go with the build: the next build
    /// converts the NSZ again.
    public func conflict(_ file: CleanupFile) -> String? {
        guard !selection.contains(file.url),
            let group = groups.first(where: { $0.files.contains(file) })
        else { return nil }
        let selected = group.files.filter { selection.contains($0.url) }
        switch file.role {
        case .original where selected.contains { $0.role == .build }:
            return "Its build is selected: these files are needed to build it again."
        case .build where selected.contains { $0.role == .original }:
            return "Its game files are selected: the build is how it plays without them."
        default:
            return nil
        }
    }

    public func isAvailable(_ file: CleanupFile) -> Bool {
        file.blocked == nil && conflict(file) == nil
    }

    /// true: all of its files that can be picked, false: none, nil: some.
    public func isSelected(_ files: [CleanupFile]) -> Bool? {
        let candidates = files.filter { selection.contains($0.url) || isAvailable($0) }
        let count = candidates.filter { selection.contains($0.url) }.count
        return count == 0 ? false : count == candidates.count ? true : nil
    }

    public func isSelected(_ group: CleanupGroup) -> Bool? { isSelected(group.files) }
    public func isSelected(_ kind: CleanupKind) -> Bool? { isSelected(files(kind)) }

    /// Selects every file of them that can be picked, or none when all are selected. One at a time, builds first: a
    /// game picked whole keeps its game files, so it can be built again.
    public func toggle(_ files: [CleanupFile]) {
        if isSelected(files) == true {
            selection.subtract(files.map(\.url))
            return
        }
        for file in files.sorted(by: { ($0.role == .build ? 0 : 1) < ($1.role == .build ? 0 : 1) })
        where isAvailable(file) {
            selection.insert(file.url)
        }
    }

    public func toggle(_ group: CleanupGroup) { toggle(group.files) }
    public func toggle(_ kind: CleanupKind) { toggle(files(kind)) }
    public func toggle(_ file: CleanupFile) { toggle([file]) }

    /// Deletes the selected files and folders for good (not to the Trash: the point is the space). Scan
    /// first, so a game that became busy meanwhile is skipped.
    public func delete() async {
        let files = selectedFiles.filter { $0.blocked == nil }
        guard canDelete, !files.isEmpty else { return }
        phase = .deleting
        let failures = await Task.detached {
            files.reduce(into: [URL: String]()) { failures, file in
                do {
                    if file.role == .build {
                        for item in CleanupScanner.buildContents(file.url) {
                            try FileManager.default.removeItem(at: item)
                        }
                    } else if file.role == .macApp {
                        try FileManager.default.removeItem(at: file.url)
                        // nxnative's record of what it packed, for the next Make Mac App: no use without the app
                        let key = CleanupScanner.appKey(file.url)
                        if FileManager.default.fileExists(atPath: key.path) {
                            try FileManager.default.removeItem(at: key)
                        }
                    } else {
                        try FileManager.default.removeItem(at: file.url)
                    }
                } catch {
                    failures[file.url] = error.localizedDescription
                }
            }
        }.value
        let removed = files.filter { failures[$0.url] == nil }
        let size = removed.reduce(0) { $0 + $1.size }
        selection = Set(failures.keys)
        confirmation = ""
        phase =
            failures.isEmpty
            ? .done(count: removed.count, size: size)
            : .failed(
                "\(removed.count) of \(files.count) removed. Not removed: "
                    + failures.map { "\($0.key.lastPathComponent) (\($0.value))" }.sorted().joined(
                        separator: "; "))
    }
}
