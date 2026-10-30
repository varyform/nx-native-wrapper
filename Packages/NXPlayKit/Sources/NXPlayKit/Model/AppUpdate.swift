import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// Updates from GitHub releases, for a released (Developer ID) NX Play only: a build from the checkout never replaces
/// itself. On launch and once a day it asks GitHub for the latest release. A newer one's DMG is downloaded, checked
/// against the SHA-256 GitHub gives for it, mounted out of sight, and its app checked: notarized, signed by the same
/// team as the running app, the same bundle ID and the release's version. The app is copied out (staged) and
/// replaces this one when NX Play quits, or at once with Restart to Update, which waits until nothing runs.
@MainActor @Observable
public final class AppUpdater {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        /// Staged in AppHome/Updates: installed when NX Play quits. Its changes since this version.
        case ready(version: String, notes: Changelog)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastCheck: Date?
    /// When the staged update became ready: after a few days still running, the reminder gets warmer.
    public private(set) var readySince: Date?
    /// A reason updates can't work that the player can fix (NX Play run from the DMG or Downloads): the library says
    /// so. Passing problems (offline, GitHub busy) only show in Settings › Updates and are tried again the next day.
    public private(set) var problem: String?
    public let currentVersion: String
    /// A released app (Developer ID, no checkout): only that one updates itself.
    public let isEnabled: Bool

    static let latestRelease = URL(
        string: "https://api.github.com/repos/varyform/nx-native-wrapper/releases/latest")!

    @ObservationIgnored private let bundle: URL
    @ObservationIgnored private let teamID: String?
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var relaunchAfterInstall = false
    /// A faked state (tests, screenshots, -NXPlayPreviewUpdate): quitting installs nothing, whatever is staged.
    @ObservationIgnored private var previewing = false
    @ObservationIgnored let folder: URL

    public init(bundle: Bundle = .main, folder: URL = AppHome.folder.appending(path: "Updates")) {
        self.bundle = bundle.bundleURL
        self.folder = folder
        currentVersion =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        bundleID = bundle.bundleIdentifier ?? ""
        teamID = Self.ownTeamID()
        isEnabled = teamID != nil && AppHome.sourceRoot == nil
    }

    /// Checks now and once a day, while the app runs.
    func start() {
        guard isEnabled, timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    public func check() async {
        guard isEnabled else { return }
        // opened from the DMG or from Downloads, macOS runs a read-only copy (App Translocation): nothing to replace
        guard !bundle.path.contains("/AppTranslocation/"),
            FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        else {
            problem = Self.moveToApplications
            state = .failed(Self.moveToApplications)
            return
        }
        problem = nil
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.latestRelease)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub didn't answer")
            }
            lastCheck = .now
            guard let release = Release(json: data),
                Self.isNewer(release.version, than: currentVersion)
            else {
                state = .upToDate
                return
            }
            state = .downloading(version: release.version)
            try await fetch(release)
            state = .ready(version: release.version, notes: whatsNew(in: release))
            readySince = .now
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    static let moveToApplications = "Move NX Play into Applications to get updates."

    /// Tests and screenshots: a state without GitHub.
    func preview(_ state: State, readySince: Date? = nil, problem: String? = nil) {
        previewing = true
        self.state = state
        self.readySince = readySince
        self.problem = problem
    }

    /// How long an update may wait before the reminder says how long it has: 3 days.
    static let patience: TimeInterval = 3 * 86_400

    /// The day the update has waited since, once it has waited `patience`; nil before.
    public func waitingSince(now: Date = .now) -> Date? {
        guard case .ready = state, let readySince,
            now.timeIntervalSince(readySince) >= Self.patience
        else { return nil }
        return readySince
    }

    /// The staged app opens once it has replaced this one (Restart to Update; a plain quit just installs it).
    func relaunchAfterUpdate() { relaunchAfterInstall = true }

    /// The app is quitting: a staged update takes its place once this process has ended.
    func installOnQuit() {
        guard !previewing, case .ready = state, let staged = stagedApp else { return }
        Self.swap(staged: staged, into: bundle, afterPID: getpid(), relaunch: relaunchAfterInstall)
    }

    // MARK: - Download and check

    private var stagedApp: URL? {
        let app = folder.appending(path: "staged/NX Play.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    /// Every release since this one, from the new app's changelog (one skipped release's changes too); the release's
    /// own notes when the new app carries no changelog.
    private func whatsNew(in release: Release) -> Changelog {
        let releases = stagedApp.flatMap(Changelog.of(app:))?.releases(
            after: currentVersion, upTo: release.version)
        if let releases, !releases.isEmpty { return releases }
        let notes = Changelog(markdown: release.notes)
        return Changelog(
            sections: notes.sections.map {
                Changelog.Section(
                    title: $0.title.isEmpty ? release.version : $0.title, blocks: $0.blocks)
            })
    }

    private func fetch(_ release: Release) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let (download, response) = try await URLSession.shared.download(from: release.dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("the download failed")
        }
        let dmg = folder.appending(path: release.dmg.lastPathComponent)
        try fm.moveItem(at: download, to: dmg)
        let expected = release.sha256
        let bundleID = bundleID
        let teamID = teamID
        let version = release.version
        let staged = folder.appending(path: "staged/NX Play.app")
        try await Task.detached {
            try Self.verifyDigest(of: dmg, expected: expected)
            try Self.stage(
                dmg: dmg, to: staged, bundleID: bundleID, teamID: teamID, version: version)
        }.value
        try? fm.removeItem(at: dmg)
    }

    nonisolated static func verifyDigest(of file: URL, expected: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            throw UpdateError("the download doesn't match its checksum")
        }
    }

    /// Mounts the DMG where Finder doesn't show it, checks the app in it and copies it out.
    nonisolated static func stage(
        dmg: URL, to staged: URL, bundleID: String, teamID: String?, version: String,
        assess: Bool = true
    ) throws {
        let mount = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-update-\(UUID().uuidString)")
        // disk arbitration can be busy for a moment ("Resource temporarily unavailable"), and a volume a check still
        // has open won't detach at once: a few tries each, so no image stays attached
        var attach = (code: Int32(-1), output: "")
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            attach = run(
                "/usr/bin/hdiutil",
                [
                    "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path,
                    dmg.path,
                ])
            if attach.code == 0 { break }
        }
        guard attach.code == 0 else { throw UpdateError("the DMG didn't open: \(attach.output)") }
        defer {
            for attempt in 0..<5 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
                if run("/usr/bin/hdiutil", ["detach", "-force", mount.path]).code == 0 { break }
            }
        }

        let app = mount.appending(path: "NX Play.app")
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
            info?["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError("the DMG doesn't hold NX Play \(version)") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).code == 0
        else {
            throw UpdateError("the new app's signature is broken")
        }
        let details = run("/usr/bin/codesign", ["-dv", app.path]).output
        guard let teamID, details.contains("TeamIdentifier=\(teamID)\n") else {
            throw UpdateError("the new app isn't signed by NX Play's developer")
        }
        if assess, run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).code != 0 {
            throw UpdateError("the new app isn't notarized")
        }
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = run("/usr/bin/ditto", [app.path, staged.path])
        guard copy.code == 0 else {
            throw UpdateError("copying the new app failed: \(copy.output)")
        }
    }

    /// Once the app has quit: the old bundle goes aside, the staged one takes its place (the old one comes back if
    /// that fails), and it opens again when asked. A shell outlives the app to do it.
    nonisolated static func swap(staged: URL, into bundle: URL, afterPID pid: Int32, relaunch: Bool)
    {
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            old="$2.old-$$"
            mv "$2" "$old" || exit 1
            if mv "$1" "$2"; then rm -rf "$old"; else mv "$old" "$2"; fi
            [ "$3" = 1 ] && open "$2"
            exit 0
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "swap", staged.path, bundle.path, relaunch ? "1" : "0"]
        try? process.run()
    }

    // MARK: - Release

    struct Release {
        let version: String
        let notes: String
        let dmg: URL
        let sha256: String

        /// GitHub's latest release: tag v<version>, a .dmg asset with its digest ("sha256:…"); nil without them.
        init?(json data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = object["tag_name"] as? String,
                let assets = object["assets"] as? [[String: Any]],
                let asset = assets.first(where: {
                    ($0["name"] as? String)?.hasSuffix(".dmg") == true
                }),
                let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                url.scheme == "https",
                let digest = asset["digest"] as? String, digest.hasPrefix("sha256:")
            else { return nil }
            version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            notes = object["body"] as? String ?? ""
            dmg = url
            sha256 = String(digest.dropFirst("sha256:".count))
        }
    }

    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(version)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The team in the running app's signature; nil when it is ad hoc (a build from the checkout).
    nonisolated static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> (
        code: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
