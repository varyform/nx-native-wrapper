#if DEBUG
    import AppKit
    import Foundation

    /// The README screenshots (bin/screenshots). A Debug build launched with
    /// `-NXPlayScreenshot <scene> -NXPlayScreenshotRoot <games folder> -NXPlayScreenshotReady <file>` opens one scene
    /// with the real games of that folder (their names and icons) and sample data for everything personal: paths
    /// under ~, an example Apple team and devices, a scripted build log, sample saves. It then sizes the window and
    /// writes its window number to the ready file for `screencapture -l`. Nothing runs: no nxplay, no devicectl,
    /// no Xcode accounts, and the settings go to a throwaway defaults suite.
    enum ScreenshotScene: String, CaseIterable {
        case library
        case list
        case console
        case consoleDetails = "console-details"
        case freeUpSpace = "free-up-space"
        case settings
        case transferSaves = "transfer-saves"
    }

    @MainActor
    struct Screenshots {
        let scene: ScreenshotScene
        let root: URL
        let ready: URL
        /// `-NXPlayScreenshotGame <title ID or part of the name>`: the game Console Mode shows (default: the middle one).
        var game: String? = nil

        static let windowSize = NSSize(width: 1040, height: 780)
        static let team = AppleTeam(id: "ABCDE12345", name: "Example Team", isFree: false)
        static let devices = [
            Device(
                id: "00008000-0000000000000001", name: "iPhone", model: "iPhone 17 Pro",
                osVersion: "27.0"),
            Device(
                id: "00008000-0000000000000002", name: "iPad Pro 13″",
                model: "iPad Pro 13-inch (M5)", osVersion: "27.0"),
        ]

        static func fromArguments(_ defaults: UserDefaults = .standard) -> Screenshots? {
            guard let name = defaults.string(forKey: "NXPlayScreenshot"),
                let root = defaults.string(forKey: "NXPlayScreenshotRoot"),
                let ready = defaults.string(forKey: "NXPlayScreenshotReady")
            else { return nil }
            guard let scene = ScreenshotScene(rawValue: name) else {
                fatalError(
                    "NXPlayScreenshot: no scene \(name); one of \(ScreenshotScene.allCases.map(\.rawValue))"
                )
            }
            return Screenshots(
                scene: scene, root: URL(filePath: root, directoryHint: .isDirectory),
                ready: URL(filePath: ready),
                game: defaults.string(forKey: "NXPlayScreenshotGame").flatMap {
                    $0.isEmpty ? nil : $0
                })
        }

        @MainActor func makeLibrary() -> Library {
            let suite = "com.varyform.nxplay.screenshots"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let library = Library(defaults: defaults, isScreenshot: true)
            library.nxnativePath = Self.tilde(AppHome.defaultNXNative)
            library.keysPath = "~/.switch/prod.keys"
            library.teams = [Self.team]
            library.devices = Self.devices
            library.root = root
            library.screenshotScene = scene
            library.allowOtherMetal = true
            library.showsLog = scene != .list

            // the game the scene is about: one built for the Mac, with its icon, else any extracted one
            let extracted = library.games.filter(\.isExtracted)
            guard
                let game = extracted.first(where: { $0.state == .ready && $0.iconURL != nil })
                    ?? extracted.first
            else {
                report("error: no extracted game in \(root.path)")
                return library
            }
            library.selection = game.id
            switch scene {
            case .library:
                library.jobs[game.id] = job(for: game, finished: false)
            case .list:
                library.viewStyle = .list
                library.jobs[game.id] = job(for: game, finished: false)
            case .console, .consoleDetails:
                library.gamepad.sample = [("Pro Controller", 0.8), ("Xbox Controller", 0.55)]
                library.consoleMode = true
                // the game asked for, else the middle of the carousel, so games show on both sides
                let carousel = library.navigableGames
                let asked = self.game.flatMap { wanted in
                    carousel.first {
                        $0.titleID?.caseInsensitiveCompare(wanted) == .orderedSame
                            || $0.name.localizedStandardContains(wanted)
                    }
                }
                library.selection = (asked ?? carousel[carousel.count / 2]).id
                if scene == .consoleDetails {
                    library.showsDetails = true
                    library.selectedGame.map(library.loadScreenshots)
                }
            case .freeUpSpace, .settings:
                break  // RootView opens their windows
            case .transferSaves:
                library.jobs[game.id] = job(for: game, finished: true)
                library.transfer = transfer(for: game)
            }
            Task { @MainActor in await present(library) }
            return library
        }

        // MARK: - Sample data

        private func job(for game: Game, finished: Bool) -> Job {
            let command = NXPlayCommand(
                script: URL(filePath: "/usr/bin/true"),
                arguments: ["--rebuild", "--build-only", Self.tilde(game.folder.path)],
                environment: [:])
            let job = Job(kind: .rebuild, game: game, command: command)
            job.showScreenshot(
                buildLog(game, finished: finished), status: finished ? .succeeded : .running)
            return job
        }

        /// What `nxplay --rebuild` prints after a pull: its own lines, then build_ipa_from_nsp.py's `--progress json`
        /// events, which the log shows as lines and the progress bar follows.
        private func buildLog(_ game: Game, finished: Bool) -> [String] {
            let titleID = game.titleID ?? "0100000000000000"
            let work = Self.tilde(game.buildFolder?.path ?? game.folder.path + "/\(titleID)_build")
            let version =
                game.buildFolder.flatMap {
                    GameScanner.extractVersions(in: $0).first?.lastPathComponent
                } ?? "v0"
            let yellow = "\u{1B}[33m"
            let dim = "\u{1B}[2m"
            let reset = "\u{1B}[m"
            let start = Calendar.current.date(bySettingHour: 21, minute: 14, second: 0, of: .now)!
            func t(_ s: Int) -> String { String(format: "[21:14:%02d]", s) }
            func event(_ s: Int, _ fields: [String: Any]) -> String {
                var fields = fields
                let kind = fields.removeValue(forKey: "ev")!
                fields["t"] = start.timeIntervalSince1970 + Double(s)
                let body = String(
                    decoding: try! JSONSerialization.data(
                        withJSONObject: fields, options: [.sortedKeys]),
                    as: UTF8.self)
                return #"{"ev": ""# + "\(kind)\", " + body.dropFirst()  // the event first, as the script writes it
            }
            func say(_ s: Int, _ msg: String) -> String {
                event(s, ["ev": "say", "msg": "\(t(s)) \(msg)"])
            }
            func stage(_ s: Int, _ k: Int, _ name: String, _ step: String = "") -> String {
                event(s, ["ev": "stage", "k": k, "n": 6, "name": name, "step": step])
            }
            func end(_ s: Int, _ k: Int, _ name: String, _ elapsed: Double, _ summary: String = "")
                -> String
            {
                event(
                    s,
                    [
                        "ev": "stage_end", "k": k, "name": name, "ok": true, "summary": summary,
                        "elapsed": elapsed,
                    ])
            }
            var lines = [
                "nxnative updated: 2 new commits, rebuilding",
                "  \(yellow)4c1d2e9\(reset) Match verified game patches across compatible updates \(dim)(nxnative, 2 hours ago)\(reset)",
                "  \(yellow)9b70f3a\(reset) Guard Metal image atomics and reject unsupported bindings \(dim)(nxnative, 3 hours ago)\(reset)",
                say(17, "game profile: \(titleID)"),
                say(
                    17,
                    "Mac-only build for development: the Mac shaders and the Mac host, no iOS shaders, Xcode project or IPA"
                ),
                say(
                    17,
                    "work folder (extracted game files in extract/, kept for the next build): \(work)"
                ),
                say(18, "base: \(game.name) [\(titleID)][v0].nsp"),
                stage(18, 1, "build nx_extract"), end(18, 1, "build nx_extract", 0.2),
                stage(18, 2, "extract \(version)"),
                say(18, "reusing the extracted \(version): \(work)/extract/\(version)"),
                end(18, 2, "extract \(version)", 0.1, "reused"),
                say(18, "game language: en-US (American English)"),
                stage(18, 3, "rewrite", "checking the inputs"),
                end(21, 3, "rewrite", 3, "main, sdk"),
                stage(21, 4, "shader split", "checking the inputs"),
                end(21, 4, "shader split", 0.3, "46 shaders, reused (inputs unchanged)"),
                stage(21, 5, "Mac shaders", "checking the inputs"),
                end(22, 5, "Mac shaders", 1, "46 of 46 shaders ready, reused (inputs unchanged)"),
                stage(22, 6, "Mac host", "building"),
                event(
                    52,
                    [
                        "ev": "progress", "k": 6, "name": "Mac host", "step": "building",
                        "done": 64, "total": 100,
                        "unit": "", "est": false, "note": "", "frac": 0.64, "eta": 17,
                        "elapsed": 30,
                    ]),
            ]
            if finished {
                lines += [
                    end(59, 6, "Mac host", 37, "\(work)/tools/dmhost"),
                    say(
                        59,
                        "done: the game runs on the Mac with this command (its save in \(work)/run/save, kept from run to run):"
                    ),
                    "saved: \(work)/start_mac.sh",
                    "nxplay: done",
                ]
            }
            return lines
        }

        /// A save newer on this Mac than on the iPad, the case Transfer Saves warns about.
        @MainActor private func transfer(for game: Game) -> SaveTransfer {
            let titleID = (game.titleID ?? "").lowercased()
            let transfer = SaveTransfer(game: game, preferredBundleID: nil)
            let app = DeviceApp(
                bundleID: "org.nxnative.abcde12345.\(titleID)", name: game.name,
                version: game.version ?? "1.0")
            let now = Date.now
            transfer.device = Self.devices[1]
            transfer.apps = [app]
            transfer.app = app
            let options = SaveFile(
                path: "options.dat", size: 2_048, modified: now.addingTimeInterval(-3 * 86400))
            transfer.macFiles = [
                SaveFile(
                    path: "save.dat", size: 479_360,
                    modified: now.addingTimeInterval(-2 * 3600 - 300)),
                options,
            ]
            transfer.deviceFiles = [
                SaveFile(
                    path: "save.dat", size: 471_040,
                    modified: now.addingTimeInterval(-6 * 3600 - 1260)),
                options,
            ]
            transfer.phase = .idle
            return transfer
        }

        // MARK: - Capture

        /// Dark, frontmost, at a fixed size; then the window number of the scene's window.
        @MainActor private func present(_ library: Library) async {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .seconds(1))
            NSApp.activate()
            let windows = NSApp.windows.filter {
                $0.isVisible && $0.sheetParent == nil && $0.level == .normal
            }
            let main = windows.max {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
            let ownWindow = scene == .settings || scene == .freeUpSpace
            if let main, !ownWindow {
                main.setContentSize(Self.windowSize)
                main.center()
            }
            // layout, icons, the sheet's animation; full screen and Free Up Space's measuring take longer
            try? await Task.sleep(
                for: .seconds(
                    scene == .console || scene == .consoleDetails || scene == .freeUpSpace ? 4 : 1.5
                ))
            let target =
                ownWindow
                ? NSApp.windows.first {
                    $0.isVisible && $0 !== main && $0.sheetParent == nil && $0.level == .normal
                }
                : main
            target?.makeKeyAndOrderFront(nil)
            target?.makeFirstResponder(nil)  // no focused, selected text field
            try? await Task.sleep(for: .seconds(0.5))
            report(
                target.map { String($0.windowNumber) } ?? "error: no window for \(scene.rawValue)")
        }

        private func report(_ text: String) {
            try? (text + "\n").write(to: ready, atomically: true, encoding: .utf8)
        }

        static func tilde(_ path: String) -> String {
            (path as NSString).abbreviatingWithTildeInPath
        }
    }
#endif
