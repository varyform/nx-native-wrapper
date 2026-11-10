import AppKit
import Foundation
import Observation

/// NX Play › Uninstall NX Play…: everything NX Play put on this Mac, and only that. Its folder (what Setup installed:
/// nxnative, Python, uv's cache, a staged update), its settings, caches and saved window state, and the app, which goes
/// to the Trash; the Homebrew tools Setup installed only when asked, since other software may use them. Never the
/// games folder (the games, their builds and the Mac saves in them), prod.keys or the save backup repository: those
/// are the player's. A checkout build's .venv and nxnative are the checkout's and stay too.
///
/// The app quits to finish: settings and window state are written as an app quits, so a shell that outlives it
/// removes them, with the folders, once it has exited.
@MainActor @Observable
public final class Uninstaller {
    public struct Item: Identifiable, Sendable {
        public enum Kind: Sendable { case folder, settings, dock, app }
        public let id: String
        public let title: String
        public let detail: String
        public let kind: Kind
        public let url: URL?
        public var size: Int64?
    }

    public enum Phase: Equatable, Sendable {
        case idle, removingTools, finishing
        case failed(String)
    }

    public private(set) var items: [Item] = []
    /// A Brewfile tool that is installed now (Setup installs them; something else may have, too).
    public struct Tool: Identifiable, Sendable {
        public let name: String
        public let cask: Bool
        /// Installed formulae that depend on it: Homebrew refuses to remove it, so it's kept.
        public let neededBy: [String]
        public var id: String { name }
    }

    public private(set) var tools: [Tool] = []
    /// The tools nothing else installed needs: the ones the checkbox removes.
    public var removableTools: [Tool] { tools.filter(\.neededBy.isEmpty) }
    public var removeTools = false
    public private(set) var phase: Phase = .idle
    public private(set) var log = LogBuffer()

    let home: URL
    let appHome: URL
    let bundle: URL
    let domain: String
    /// The Dock's preferences: pinned apps are its persistent-apps (another domain in tests).
    let dockDomain: String

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, appHome: URL = AppHome.folder,
        bundle: URL = Bundle.main.bundleURL,
        domain: String = Bundle.main.bundleIdentifier ?? "com.varyform.nxplay",
        dockDomain: String = "com.apple.dock"
    ) {
        self.home = home
        self.appHome = appHome
        self.bundle = bundle
        self.domain = domain
        self.dockDomain = dockDomain
        items = Self.items(home: home, appHome: appHome, bundle: bundle, domain: domain)
        if Self.dockEntries(of: domain, in: dockDomain) > 0 {
            items.insert(
                Item(
                    id: "dock", title: "Dock icon",
                    detail: "NX Play kept in the Dock; the Dock restarts",
                    kind: .dock, url: nil),
                at: items.count - 1)
        }
    }

    // MARK: - Dock

    /// How many of the Dock's pinned apps are this app (by bundle ID, so a copy outside Applications counts too).
    nonisolated static func dockEntries(of bundleID: String, in dockDomain: String) -> Int {
        pinnedApps(dockDomain).filter { isEntry($0, of: bundleID) }.count
    }

    /// Unpins the app: persistent-apps without its entries, through cfprefsd as `defaults write` does, so the Dock
    /// reads it when it restarts; nothing else in the list changes. The Dock has no public API for this; uninstallers
    /// do it this way. → how many entries went.
    @discardableResult
    nonisolated static func removeDockEntries(of bundleID: String, in dockDomain: String) -> Int {
        let apps = pinnedApps(dockDomain)
        let kept = apps.filter { !isEntry($0, of: bundleID) }
        guard kept.count < apps.count else { return 0 }
        CFPreferencesSetAppValue(
            "persistent-apps" as CFString, kept as CFArray, dockDomain as CFString)
        CFPreferencesAppSynchronize(dockDomain as CFString)
        return apps.count - kept.count
    }

    nonisolated private static func pinnedApps(_ dockDomain: String) -> [[String: Any]] {
        CFPreferencesAppSynchronize(dockDomain as CFString)
        return CFPreferencesCopyAppValue("persistent-apps" as CFString, dockDomain as CFString)
            as? [[String: Any]] ?? []
    }

    nonisolated private static func isEntry(_ app: [String: Any], of bundleID: String) -> Bool {
        (app["tile-data"] as? [String: Any])?["bundle-identifier"] as? String == bundleID
    }

    /// What there is to remove, existing items only; sizes come later (measure).
    nonisolated static func items(home: URL, appHome: URL, bundle: URL, domain: String) -> [Item] {
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let fm = FileManager.default
        var items: [Item] = []
        func folder(_ id: String, _ title: String, _ detail: String, _ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            items.append(Item(id: id, title: title, detail: detail, kind: .folder, url: url))
        }
        folder(
            "home", "NX Play's folder", "nxnative, Python and its packages, a downloaded update",
            appHome)
        folder(
            "caches", "Caches", "Downloaded artwork and web caches",
            library.appending(path: "Caches/\(domain)"))
        folder(
            "http", "Web storage", "Cookies and caches of GitHub requests",
            library.appending(path: "HTTPStorages/\(domain)"))
        folder(
            "state", "Window state", "Where the windows were",
            library.appending(path: "Saved Application State/\(domain).savedState"))
        items.append(
            Item(
                id: "settings", title: "Settings",
                detail: "The games folder, the paths and every choice in Settings",
                kind: .settings, url: library.appending(path: "Preferences/\(domain).plist")))
        items.append(
            Item(
                id: "app", title: "NX Play", detail: "The app, moved to the Trash", kind: .app,
                url: bundle))
        return items
    }

    /// Sizes of the folders and the app; the Brewfile tools installed now.
    public func measure() async {
        let measured = await Task.detached { [items] in
            items.map { item -> Item in
                var item = item
                item.size = item.url.map(Self.size(of:))
                return item
            }
        }.value
        items = measured
        let listed = await Task.detached { Self.installedTools() }.value
        tools = listed
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard
            let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Homebrew

    /// The Brewfile bundled with the setup: its formulae and casks, and the ones marked `# retired:` that Setup no
    /// longer installs but did before (Homebrew skips them as comments).
    nonisolated static func brewfileTools(
        _ brewfile: URL? = AppHome.setupProject?.appending(path: "Brewfile")
    )
        -> [(name: String, cask: Bool)]
    {
        guard let brewfile, let text = try? String(contentsOf: brewfile, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^(?:#\s*retired:\s*)?(brew|cask)\s+"([^"]+)"/) else {
                return nil
            }
            return (String(match.2), match.1 == "cask")
        }
    }

    /// The Brewfile's tools installed now, each with the installed formulae that depend on it (zstd is a dependency of
    /// llvm, node, python and many more: Homebrew won't remove it, and shouldn't).
    nonisolated static func installedTools(
        brewfile: URL? = AppHome.setupProject?.appending(path: "Brewfile")
    ) -> [Tool] {
        guard let brew = brewPath else { return [] }
        let list = { (kind: String) in
            Set(lines(Self.run(brew, ["list", "-1", kind]).output))
        }
        let formulae = list("--formula")
        let casks = list("--cask")
        return brewfileTools(brewfile).compactMap { tool in
            guard (tool.cask ? casks : formulae).contains(tool.name) else { return nil }
            let users =
                tool.cask ? [] : lines(Self.run(brew, ["uses", "--installed", tool.name]).output)
            return Tool(name: tool.name, cask: tool.cask, neededBy: users)
        }
    }

    /// A command's output lines that are names: Homebrew's warnings about other taps go to the same pipe.
    nonisolated static func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter {
            !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("/")
        }
    }

    nonisolated static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(
            where: FileManager.default.isExecutableFile)
    }

    // MARK: - Uninstall

    /// Removes the tools when asked, moves the app to the Trash, and quits; the shell started here removes the rest
    /// once NX Play has exited.
    public func uninstall(environment: [String: String]) async {
        guard phase != .removingTools, phase != .finishing else { return }
        phase = .idle
        log = LogBuffer()
        // one by one, only the ones nothing else needs: one that still can't go is kept and noted, and the rest of
        // the uninstall goes on (one brew command for all failed as a whole on a shared dependency)
        if removeTools, let brew = Self.brewPath {
            phase = .removingTools
            for tool in removableTools {
                let kind = tool.cask ? "--cask" : "--formula"
                log.append(["$ brew uninstall \(kind) \(tool.name)"])
                let result = await Task.detached {
                    Self.run(brew, ["uninstall", kind, tool.name], environment: environment)
                }.value
                log.append(result.output.split(separator: "\n").map(String.init))
                if result.code != 0 {
                    log.append(["\(tool.name) stays: Homebrew couldn't remove it"])
                }
            }
        }
        phase = .finishing
        // the Dock restarts while NX Play still runs: one that stayed up could write its list, pin included, back
        if Self.removeDockEntries(of: domain, in: dockDomain) > 0, dockDomain == "com.apple.dock" {
            _ = await Task.detached { Self.run("/usr/bin/killall", ["Dock"]) }.value
        }
        let folders = items.filter { $0.kind == .folder }.compactMap(\.url)
        Self.cleanUp(afterPID: getpid(), folders: folders, domain: domain)
        do {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
        } catch {
            log.append([
                "The app couldn't go to the Trash (\(error.localizedDescription)): drag it there yourself."
            ])
        }
        NSApp?.terminate(nil)
    }

    /// Once the process has exited: the folders go, and so do the settings (through cfprefsd, which caches them).
    nonisolated static func cleanUp(afterPID pid: Int32, folders: [URL], domain: String) {
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            domain="$1"; shift
            for folder in "$@"; do rm -rf "$folder"; done
            /usr/bin/defaults delete "$domain" 2>/dev/null
            rm -f "$HOME/Library/Preferences/$domain.plist"
            exit 0
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "cleanup", domain] + folders.map(\.path)
        try? process.run()
    }

    nonisolated static func run(
        _ tool: String, _ arguments: [String], environment: [String: String]? = nil
    )
        -> (code: Int32, output: String)
    {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
