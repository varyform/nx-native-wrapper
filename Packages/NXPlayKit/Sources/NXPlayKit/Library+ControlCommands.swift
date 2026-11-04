import AppKit
import Foundation

/// The control API's commands (Control/): the library's own operations, run on the main actor with the library the
/// window shows, so a change made here is the window's change too. A game is named by its folder's name in the games
/// folder, as the iOS app's API names it. Nothing here runs a shell, reads arbitrary files or hands out a secret:
/// paths are taken only where the window takes one (the games folder, a folder for saves), checked the same way, and
/// the pairing code and Sources' access tokens are never answered with.
extension Library {
    // MARK: - Shared

    func controlGame(_ id: String) throws(ControlError) -> Game {
        guard let game = games.first(where: { $0.folder.lastPathComponent == id }) else {
            throw .notFound("No game “\(id)” in the games folder: use the id games.list gives (its folder's name)")
        }
        return game
    }

    /// Starts an nxplay run the way the window's buttons do, through `run`. Refusals come back as errors instead of
    /// the window's alert: a problem `run` sets is taken back in the same main-actor turn, before the window draws.
    func controlStart(_ kind: Job.Kind, _ game: Game, select: Bool, appSave: URL? = nil) throws(ControlError) -> Job {
        if let job = job(for: game), job.status.isActive {
            throw .conflict("\(game.name) is busy: \(job.progressText)")
        }
        if game.isKept, kind.rewritesTheMacBuild { throw .conflict(Self.keptBuildProblem) }
        let before = problem
        let old = jobs[game.id]
        run(kind, game, select: select, appSave: appSave)
        guard let job = jobs[game.id], job !== old else {
            let message = problem ?? "\(game.name) didn't start"
            problem = before
            throw .failed(message)
        }
        return job
    }

    /// Bulk starts (Extract All, Update All Builds): each game through `controlStart`, so each refusal comes back for
    /// its game and leaves no alert. → the runs that started, and why each other game didn't.
    func controlStartAll(_ kind: Job.Kind, _ games: [Game]) -> (started: [Job], refused: [String: String]) {
        var started: [Job] = []
        var refused: [String: String] = [:]
        for game in games {
            do throws(ControlError) {
                started.append(try controlStart(kind, game, select: false))
            } catch {
                refused[game.folder.lastPathComponent] = error.message
            }
        }
        return (started, refused)
    }

    /// The answer of a bulk start: what started and what didn't, or an error when none of it did.
    func controlBulkAnswer(_ what: String, started: [Job], refused: [String: String], extra: [String: Any] = [:])
        throws(ControlError) -> ControlOutcome
    {
        guard !started.isEmpty else {
            let reasons = refused.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            throw ControlError(
                code: "command_failed", status: 422, message: "No game started to \(what): \(reasons)", details: refused)
        }
        var json = extra
        json["queued"] = started.map(\.game.folder.lastPathComponent)
        json["refused"] = refused
        return .value(json)
    }

    func controlGameJSON(_ game: Game, full: Bool) -> [String: Any] {
        var json = remoteJSON(game)
        json["folder"] = game.folder.path
        json["isDump"] = game.isDump
        json["isSwitch2"] = game.isSwitch2
        json["copying"] = game.isCopying
        json["hasGameFiles"] = game.hasPackages
        json["lastPlayed"] = game.lastPlayed ?? NSNull()
        json["selected"] = selection == game.id
        json["actions"] = controlActions(game)
        if full {
            json["languages"] = game.languages
            json["ipa"] = game.ipaURL?.path ?? NSNull()
            json["macApp"] = game.macAppURL?.path ?? NSNull()
            json["macAppOutdated"] = game.macAppOutdated
            json["build"] = game.buildFolder?.path ?? NSNull()
            json["hasProfile"] = profile(game) != nil
            json["profileNews"] = news(game).count
            json["saveChoice"] = saveChoice(for: game)?.rawValue ?? NSNull()
        }
        return json
    }

    /// What the Game menu would let the player do now (GameActions' conditions).
    func controlActions(_ game: Game) -> [String] {
        // Free Up Space or Remove Game is deleting its files: nothing until that's done
        guard !isReserved(game) else { return [] }
        let busy = isBusy(game)
        var actions: [String] = []
        if !game.isExtracted, !busy, game.canExtract { actions.append("extract") }
        if !busy { actions.append("play") }
        if busy { actions.append("stop") }
        if !busy, game.isExtracted, game.canBuildFromFiles { actions.append("rebuild") }
        if !busy, !game.isKept, game.canBuildIPA { actions.append("build_ipa") }
        if !busy, !game.isKept, game.isExtracted, game.canBuildFromFiles {
            actions.append(contentsOf: ["make_mac_app", "install"])
        }
        if game.canKeep { actions.append("set_kept") }
        if game.state == .ready, game.titleID != nil { actions.append("settings") }
        if canRemove(game) { actions.append("remove") }
        return actions
    }

    func controlSettingsJSON() -> [String: Any] {
        let fm = FileManager.default
        let keys = (keysPath as NSString).expandingTildeInPath
        return [
            "gamesFolder": root?.path ?? NSNull(),
            "controllerPlayers": controllerPlayers.rawValue,
            "globalChoices": globalChoices,
            "allowOtherMetal": allowOtherMetal,
            "updateBeforePlay": updateBeforePlay.rawValue,
            "teamID": teamID,
            "team": team.map { ["id": $0.id, "name": $0.name, "free": $0.isFree] } ?? NSNull(),
            "teams": teams.map { ["id": $0.id, "name": $0.name, "free": $0.isFree] },
            "viewStyle": viewStyle.rawValue,
            "showsLog": showsLog,
            "cloudSaves": cloudSaves,
            "saveBackupPath": saveBackupPath,
            "saveChoices": saveChoices.mapValues(\.rawValue),
            // read only here: these name the code builds run and the keys they read; change them in Settings
            "nxnativePath": nxnativePath,
            "keysPath": keysPath,
            "keysFileExists": fm.fileExists(atPath: keys),
            // the iOS app's server: read only; its pairing code is never shown here
            "remoteEnabled": remoteEnabled,
            "remotePort": Int(remotePort),
        ]
    }

    /// The settings the API may change, and how each is checked. Paths and the iOS app's server are left to the
    /// Settings window: nxnativePath and keysPath name code and keys that builds run with.
    static let controlWritableSettings: [ControlParam] = [
        ControlParam(
            "controllerPlayers", .string(choices: ControllerPlayers.allCases.map(\.rawValue)), required: false,
            "Players and controllers: each, keyboardOwn or merged"),
        ControlParam(
            "globalChoices", .map(.nullable(.string(maxLength: 256)), maxCount: 64), required: false,
            "Settings › Games: values by variable (DM_LANG, DM_FULLSCREEN…); null takes one back to each game's default. Merged into the current ones."
        ),
        ControlParam("allowOtherMetal", .boolean, required: false, "Build with a Metal compiler nxnative didn't test"),
        ControlParam(
            "updateBeforePlay", .string(choices: UpdateBeforePlay.allCases.map(\.rawValue)), required: false,
            "When nxnative has new code for a game: ask, update or current"),
        ControlParam("teamID", .string(maxLength: 64), required: false, "The Apple team that signs installs; empty picks one"),
        ControlParam("viewStyle", .string(choices: ViewStyle.allCases.map(\.rawValue)), required: false, "grid or list"),
        ControlParam("showsLog", .boolean, required: false, "The log panel under the games"),
        ControlParam(
            "cloudSaves", .string(maxLength: 1024), required: false,
            "Cloud saves: empty for off, icloud, or an existing folder (absolute path)"),
        ControlParam(
            "saveBackupPath", .string(maxLength: 1024), required: false,
            "A clone saves are backed up to while games play: empty for none, or an existing folder"),
    ]

    /// An existing folder (absolute, ~ allowed), or why not.
    static func controlFolder(_ text: String, _ what: String) throws(ControlError) -> String {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw .invalidArgs("\(what) must be an absolute path") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw .invalidArgs("\(what): no folder at \(path)")
        }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path
    }

    /// Checks the whole patch, then applies it in the same main-actor turn: all of it or none, never interleaved with
    /// the window's or another call's change, each key written through its property (so it's saved and drawn).
    func controlPatchSettings(_ patch: [String: Any]) throws(ControlError) -> [String] {
        if let problem = ControlParam.problem(patch, Self.controlWritableSettings, at: "patch") {
            throw .invalidArgs(problem)
        }
        let args = ControlArgs(values: patch)
        var choices: [String: String?] = [:]
        if let given = args.object("globalChoices") {
            let rows = globalSettings
            for (env, value) in given {
                guard let row = rows.first(where: { $0.env == env }) else {
                    throw .invalidArgs(
                        "patch.globalChoices.\(env) isn't a setting the games offer (\(rows.map(\.env).joined(separator: ", ")))")
                }
                if let value = value as? String {
                    guard row.accepts(value) else { throw .invalidArgs("patch.globalChoices.\(env) doesn't take “\(value)”") }
                    choices[env] = .some(value)
                } else {
                    choices[env] = .some(nil)
                }
            }
        }
        if let team = args.string("teamID"), !team.isEmpty, !teams.contains(where: { $0.id == team }) {
            throw .invalidArgs("patch.teamID: Xcode has no team \(team) (\(teams.map(\.id).joined(separator: ", ")))")
        }
        var cloud: String?
        if let value = args.string("cloudSaves") {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            cloud = trimmed.isEmpty || trimmed == "icloud" ? trimmed : try Self.controlFolder(trimmed, "patch.cloudSaves")
        }
        var backup: String?
        if let value = args.string("saveBackupPath") {
            backup = value.isEmpty ? "" : try Self.controlFolder(value, "patch.saveBackupPath")
        }
        // checked: apply
        if let value = args.string("controllerPlayers").flatMap(ControllerPlayers.init(rawValue:)) {
            controllerPlayers = value
        }
        if !choices.isEmpty {
            var merged = globalChoices
            for (env, value) in choices { merged[env] = value }
            globalChoices = merged
        }
        if let value = args.bool("allowOtherMetal") { allowOtherMetal = value }
        if let value = args.string("updateBeforePlay").flatMap(UpdateBeforePlay.init(rawValue:)) {
            updateBeforePlay = value
        }
        if let value = args.string("teamID") { teamID = value }
        if let value = args.string("viewStyle").flatMap(ViewStyle.init(rawValue:)) { viewStyle = value }
        if let value = args.bool("showsLog") { showsLog = value }
        if let cloud { cloudSaves = cloud }
        if let backup { saveBackupPath = backup }
        return patch.keys.sorted()
    }

    func controlCompanionJSON() -> [String: Any] {
        let advertisement: Any =
            switch remoteAdvertisement {
            case .off: "off"
            case .registering(let attempt): ["state": "registering", "attempt": attempt]
            case .advertised(let name): ["state": "advertised", "name": name]
            }
        let tailscale: String =
            switch remoteNetwork.tailscale.state {
            case .notInstalled: "notInstalled"
            case .installed(let state): "installed" + (state.map { " (\($0))" } ?? "")
            case .running: "running"
            }
        return [
            "enabled": remoteEnabled,
            "port": Int(remotePort),
            "listening": remoteServer?.listeningPort.map { Int($0) } ?? NSNull(),
            "problem": remoteProblem ?? NSNull(),
            "bonjour": advertisement,
            "addresses": remoteEndpoints.map { ["address": $0.display, "kind": $0.kind.rawValue] },
            "tailscale": tailscale,
            "devicesSeen": deviceGames.count,
            // the iOS app's pairing code opens the iOS app's API on the local network only; it is never shown or
            // accepted here
            "pairingCode": "not shown",
        ]
    }

    func controlUIJSON() -> [String: Any] {
        [
            "selection": selectedGame?.folder.lastPathComponent ?? NSNull(),
            "search": search,
            "consoleMode": consoleMode,
            "viewStyle": viewStyle.rawValue,
            "showsLog": showsLog,
            "settingsTab": "\(settingsTab)",
            "windowsOpenable": ControlWindow.allCases.map(\.rawValue),
            "updateQuestion": updatePrompt.map { prompt -> [String: Any] in
                [
                    "game": prompt.job.game.folder.lastPathComponent, "commits": prompt.ask.commits ?? NSNull(),
                    "shaders": prompt.ask.shaders.rawValue, "answers": ["update", "current", "cancel"],
                ]
            } ?? NSNull(),
            "saveQuestion": saveQuestion.map { question -> [String: Any] in
                [
                    "game": question.game.folder.lastPathComponent, "answers": SaveChoice.allCases.map(\.rawValue) + ["cancel"],
                    "appSave": question.appSave.folder.path,
                ]
            } ?? NSNull(),
            "sheets": [
                "removeGame": removingGame?.folder.lastPathComponent ?? NSNull(),
                "gameSettings": settingsGame?.folder.lastPathComponent ?? NSNull(),
                "transferSaves": transfer != nil, "updateAll": showsUpdateAll,
            ] as [String: Any],
            "problem": problem ?? NSNull(),
        ]
    }

    func controlStatusJSON() -> [String: Any] {
        let active = jobs.values.filter(\.status.isActive)
        return [
            "gamesFolder": root?.path ?? NSNull(),
            "games": games.count,
            "needsSetup": needsSetup,
            "idle": isIdle,
            "buildsRunning": active.filter { $0.status == .running }.count,
            "buildsQueued": active.filter { $0.status == .queued }.count,
            "waitingForPower": waitingForPower,
            "downloadsActive": repositories.downloads.filter(\.state.isActive).count,
            "devices": devices.count,
            "selection": selectedGame?.folder.lastPathComponent ?? NSNull(),
            "consoleMode": consoleMode,
            "pendingQuestion": (updatePrompt != nil ? "update" : saveQuestion != nil ? "save" : nil) as String? as Any,
        ]
    }

    /// What a folder holds, as the library would read it: the games-folder check before choosing it (Choose Games
    /// Folder…). Reads names and file types only.
    static func controlInspect(_ root: URL) async -> [[String: Any]] {
        let games = await Task.detached { GameScanner.scan(root: root) }.value
        return games.map { game in
            [
                "id": game.folder.lastPathComponent, "name": game.name, "titleID": game.titleID ?? NSNull(),
                "version": game.version ?? NSNull(), "state": "\(game.state)", "hasGameFiles": game.hasPackages,
                "isDump": game.isDump, "copying": game.isCopying, "canExtract": game.canExtract,
            ]
        }
    }

    func controlCleanupJSON(_ groups: [CleanupGroup]) -> [[String: Any]] {
        groups.map { group in
            [
                "game": group.game.folder.lastPathComponent, "name": group.game.name, "bytes": group.size,
                "files": group.files.map { file -> [String: Any] in
                    [
                        "path": file.url.path, "kind": file.kind.rawValue, "role": "\(file.role)",
                        "bytes": file.size, "measuring": file.measuring, "blocked": file.blocked ?? NSNull(),
                    ]
                },
            ]
        }
    }

    // MARK: - The commands

    /// Every command, in the order `commands` lists them.
    func controlCommands() -> [ControlCommand] {
        libraryCommands() + gameCommands() + settingsCommands() + sourceCommands() + deviceCommands()
            + cleanupCommands() + uiCommands()
    }

    private func libraryCommands() -> [ControlCommand] {
        [
            ControlCommand("library.status", "The games folder, games, builds, downloads and what's waiting for an answer", effect: .read) { _ throws(ControlError) in
                .value(self.controlStatusJSON())
            },
            ControlCommand("library.refresh", "Look at the games folder again (the window's Refresh)", effect: .write, idempotent: true) { _ throws(ControlError) in
                self.refresh()
                return .value(["games": self.games.count])
            },
            ControlCommand(
                "library.inspect_folder", "What a folder holds as a games folder, without choosing it: the check before library.set_folder",
                params: [ControlParam("path", .string(maxLength: 1024), "An existing folder, absolute (~ allowed)")], effect: .read
            ) { args throws(ControlError) in
                let path = try Self.controlFolder(args.string("path") ?? "", "path")
                let games = await Self.controlInspect(URL(filePath: path, directoryHint: .isDirectory))
                return .value([
                    "path": path, "games": games,
                    "extractable": games.filter { $0["canExtract"] as? Bool == true }.count,
                ])
            },
            ControlCommand(
                "library.set_folder", "Choose the games folder (Choose Games Folder…): saved, and the library reads it",
                params: [ControlParam("path", .string(maxLength: 1024), "An existing folder, absolute (~ allowed)")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let path = try Self.controlFolder(args.string("path") ?? "", "path")
                guard self.isIdle else { throw .conflict("Builds or downloads are running: change the games folder when they end") }
                self.root = URL(filePath: path, directoryHint: .isDirectory)
                return .value(["gamesFolder": path, "games": self.games.count])
            },
            ControlCommand("setup.status", "Whether nxnative and its Python environment are installed (Setup runs from the window)", effect: .read) { _ throws(ControlError) in
                let repo = (self.nxnativePath as NSString).expandingTildeInPath
                return .value([
                    "needsSetup": self.needsSetup,
                    "nxnative": FileManager.default.fileExists(atPath: repo + "/scripts/build_ipa_from_nsp.py"),
                    "python": FileManager.default.isExecutableFile(atPath: AppHome.venv.appending(path: "bin/python3").path),
                    "pythonCurrent": AppHome.venvIsCurrent,
                ])
            },
        ]
    }

    private func gameCommands() -> [ControlCommand] {
        let game = ControlParam("game", .string(maxLength: 512), "The game's id: its folder's name (games.list)")
        let select = ControlParam("select", .boolean, required: false, "Select the game in the window too (default false)")
        func build(_ name: String, _ summary: String, _ kind: Job.Kind, check: @escaping @MainActor (Game) throws(ControlError) -> Void) -> ControlCommand {
            ControlCommand(name, summary, params: [game, select], effect: .write, cancel: "jobs cancel (the build's Cancel)") { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                try check(target)
                let job = try self.controlStart(kind, target, select: args.bool("select") ?? false)
                return .build(job, self.remoteJSON(job))
            }
        }
        return [
            ControlCommand(
                "games.list", "The games with their state, running job and the actions they allow",
                params: [ControlParam("query", .string(maxLength: 256), required: false, "Words each game's name, title ID or folder must have")], effect: .read
            ) { args throws(ControlError) in
                let words = (args.string("query") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
                let shown = self.games.filter { game in
                    let fields = [game.name, game.titleID ?? "", game.folder.lastPathComponent]
                    return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
                }
                return .value(shown.map { self.controlGameJSON($0, full: false) })
            },
            ControlCommand("games.get", "One game in full: files, build, IPA, Mac app, profile, actions", params: [game], effect: .read) { args throws(ControlError) in
                .value(self.controlGameJSON(try self.controlGame(args.string("game") ?? ""), full: true))
            },
            ControlCommand(
                "games.log", "The game's latest nxplay output (its job's log)",
                params: [game, ControlParam("lines", .integer(min: 1, max: 2000), required: false, "How many of the last lines (default 200)")],
                effect: .read
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard let job = self.job(for: target) else { return .value(["job": NSNull(), "lines": [String]()]) }
                let lines = job.log.lines.suffix(args.int("lines") ?? 200).map(\.text)
                return .value(["job": self.remoteJSON(job), "lines": Array(lines)])
            },
            build("games.extract", "Extract and build the game (Extract), queued behind other builds", .extract) { game throws(ControlError) in
                guard game.canExtract else {
                    throw .conflict(game.isExtracted ? "\(game.name) is extracted already: use games.rebuild" : "\(game.name) has no complete game files to extract")
                }
            },
            build("games.rebuild", "Build the game again from its files (Rebuild)", .rebuild) { game throws(ControlError) in
                guard game.isExtracted, game.canBuildFromFiles else { throw .conflict("\(game.name) needs to be extracted, with its game files, to rebuild") }
            },
            build("games.build_ipa", "Build an IPA of the game (Build IPA)", .ipa) { game throws(ControlError) in
                guard game.canBuildIPA else { throw .conflict("\(game.name) has no game files to build an IPA from") }
            },
            build("games.make_mac_app", "Pack a standalone Mac app of the game (Make Mac App)", .macApp) { game throws(ControlError) in
                guard game.isExtracted, game.canBuildFromFiles else { throw .conflict("\(game.name) needs to be extracted, with its game files") }
            },
            ControlCommand(
                "games.install", "Build the game signed with the team and install it on a device (Install on Device)",
                params: [game, ControlParam("device", .string(maxLength: 128), "The device's UDID (devices.list)"), select],
                effect: .write, openWorld: true, cancel: "jobs cancel (the build's Cancel)"
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard target.isExtracted, target.canBuildFromFiles else { throw .conflict("\(target.name) needs to be extracted, with its game files") }
                let udid = args.string("device") ?? ""
                if !self.devices.contains(where: { $0.id == udid }), !self.isScreenshot { self.devices = await Device.load() }
                guard let device = self.devices.first(where: { $0.id == udid }) else {
                    throw .notFound("The Mac can't reach device \(udid): pair it with Xcode, with Connect via network on (devices.list)")
                }
                let job = try self.controlStart(.install(device), target, select: args.bool("select") ?? false)
                return .build(job, self.remoteJSON(job))
            },
            ControlCommand(
                "games.play", "Play the game (Play): builds first when it isn't ready; may wait for an answer (games.answer_update / games.answer_save)",
                params: [game, select], effect: .write, cancel: "jobs cancel (Stop)"
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                if let job = self.job(for: target), job.status.isActive { throw .conflict("\(target.name) is busy: \(job.progressText)") }
                let old = self.jobs[target.id]
                let before = self.problem
                if args.bool("select") == true { self.selection = target.id }
                self.play(target)
                if let job = self.jobs[target.id], job !== old { return .build(job, self.remoteJSON(job)) }
                if let question = self.saveQuestion, question.game.id == target.id {
                    return .value(["started": false, "waitingFor": "save_question", "ui": self.controlUIJSON()["saveQuestion"] ?? NSNull()])
                }
                let message = self.problem ?? "\(target.name) didn't start"
                self.problem = before
                throw .failed(message)
            },
            ControlCommand(
                "games.stop", "Stop the game's running or queued job, whoever started it (Stop / Cancel)", params: [game], effect: .write
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard let job = self.job(for: target), job.status.isActive else { throw .conflict("\(target.name) has nothing running") }
                job.cancel()
                return .value(self.remoteJSON(job))
            },
            ControlCommand(
                "games.answer_update", "Answer nxplay's question before a play: update nxnative first, play the current build, or don't play",
                params: [ControlParam("answer", .string(choices: ["update", "current", "cancel"]), "update, current or cancel"),
                         ControlParam("game", .string(maxLength: 512), required: false, "The game asked about, to be sure it's that one")],
                effect: .write
            ) { args throws(ControlError) in
                guard let prompt = self.updatePrompt else { throw .conflict("No play is waiting for an update answer") }
                if let id = args.string("game"), prompt.job.game.folder.lastPathComponent != id {
                    throw .conflict("The question is about \(prompt.job.game.folder.lastPathComponent), not \(id)")
                }
                self.answerUpdate(UpdateAnswer(rawValue: args.string("answer") ?? "") ?? .cancel)
                return .value(["answered": prompt.job.game.folder.lastPathComponent])
            },
            ControlCommand(
                "games.answer_save", "Answer which save a play uses when the Mac app's own differs: nxplay, app, newer, or cancel",
                params: [ControlParam("choice", .string(choices: SaveChoice.allCases.map(\.rawValue) + ["cancel"]), "nxplay, app, newer or cancel"),
                         ControlParam("remember", .boolean, required: false, "Don't ask again for this game"),
                         ControlParam("game", .string(maxLength: 512), required: false, "The game asked about, to be sure it's that one")],
                effect: .write
            ) { args throws(ControlError) in
                guard var question = self.saveQuestion else { throw .conflict("No play is waiting for a save answer") }
                let id = question.game.folder.lastPathComponent
                if let given = args.string("game"), given != id { throw .conflict("The question is about \(id), not \(given)") }
                question.remember = args.bool("remember") ?? false
                self.saveQuestion = question
                let choice = SaveChoice(rawValue: args.string("choice") ?? "")
                let old = self.jobs[question.game.id]
                self.answerSaveQuestion(choice)
                if let job = self.jobs[question.game.id], job !== old { return .build(job, self.remoteJSON(job)) }
                return .value(["answered": id, "started": false])
            },
            ControlCommand(
                "games.set_kept", "Keep This Build on or off: a kept build isn't rebuilt by nxnative updates",
                params: [game, ControlParam("kept", .boolean, "true to keep the build")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard target.canKeep else { throw .conflict("\(target.name) has no build that plays to keep") }
                // the window's own setter: refused while Free Up Space or Remove Game holds the game
                switch self.changeKept(args.bool("kept") ?? false, target) {
                case .reserved(let message)?: throw .conflict(message)
                case .failed(let message)?: throw .failed(message)
                case nil: break
                }
                return .value(self.controlGameJSON(try self.controlGame(target.folder.lastPathComponent), full: false))
            },
            ControlCommand("games.settings", "The game's settings: each with its own, global and default value (Game Settings…)", params: [game], effect: .read) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard let list = self.settingsLists[target.id] ?? self.gameSettings(for: target) else {
                    return .value(["game": target.folder.lastPathComponent, "settings": [Any](), "note": "No settings list before the game's first build"])
                }
                return .value([
                    "game": target.folder.lastPathComponent,
                    "settings": list.settings.map { setting -> [String: Any] in
                        var json: [String: Any] = [
                            "env": setting.env, "label": setting.label, "section": setting.section, "note": setting.note,
                            "default": setting.defaultValue, "value": self.value(setting, for: target),
                            "own": self.own(setting, for: target) ?? NSNull(), "global": self.globalValue(setting, for: target) ?? NSNull(),
                            "basic": setting.isBasic,
                        ]
                        switch setting.kind {
                        case .choice(let options): json["choices"] = options.map { ["value": $0.value, "label": $0.label] }
                        case .range(let min, let max, let step): json["range"] = ["min": min, "max": max, "step": step]
                        case .toggle(let on, let off): json["toggle"] = ["on": on, "off": off]
                        }
                        return json
                    },
                ])
            },
            ControlCommand(
                "games.set_setting", "Set one of the game's own settings, or null to follow the global value",
                params: [game, ControlParam("env", .string(maxLength: 64), "The setting's variable (games.settings)"),
                         ControlParam("value", .nullable(.string(maxLength: 256)), "A value it accepts, or null")],
                effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard target.titleID != nil, let list = self.settingsLists[target.id] ?? self.gameSettings(for: target) else {
                    throw .conflict("\(target.name) has no settings list yet: build it first")
                }
                let env = args.string("env") ?? ""
                guard let setting = list[env] else { throw .invalidArgs("\(target.name) has no setting \(env)") }
                let value = args.string("value")
                if let value, !setting.accepts(value) { throw .invalidArgs("\(env) doesn't take “\(value)”") }
                self.setOwn(value, setting, for: target)
                return .value(["env": env, "own": self.own(setting, for: target) as Any, "value": self.value(setting, for: target)])
            },
            ControlCommand("games.clear_settings", "Use Global Settings: the game follows every global value again", params: [game], effect: .write, idempotent: true) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                guard let list = self.settingsLists[target.id] ?? self.gameSettings(for: target) else {
                    throw .conflict("\(target.name) has no settings list yet")
                }
                self.clearOwn(list, for: target)
                return .value(["game": target.folder.lastPathComponent, "cleared": list.settings.count])
            },
            ControlCommand("games.forget_save_choice", "Ask again which save to play with (Game Settings › Ask Again)", params: [game], effect: .write, idempotent: true) { args throws(ControlError) in
                let target = try self.controlGame(args.string("game") ?? "")
                self.forgetSaveChoice(for: target)
                return .value(["game": target.folder.lastPathComponent])
            },
            ControlCommand(
                "games.extract_all", "Extract every game not extracted yet, one after another (Extract All)", effect: .write
            ) { _ throws(ControlError) in
                // the window's Extract All, game by game through the refusal-aware start: only what started is
                // reported as queued, and a refusal is this call's error, never an alert left in the window
                let candidates = self.extractableGames
                guard !candidates.isEmpty else {
                    throw .conflict("No game to extract: each is extracted already, busy, or without complete game files")
                }
                let (started, refused) = self.controlStartAll(.extract, candidates)
                return try self.controlBulkAnswer("extract", started: started, refused: refused)
            },
            ControlCommand(
                "games.update_all", "Bring every built game up to date with nxnative, one build after another (Update All Builds…)",
                params: [ControlParam("onlyWhilePluggedIn", .boolean, required: false, "Wait while the Mac is on battery")], effect: .write
            ) { args throws(ControlError) in
                // Library.updateAll's steps, each game started through the refusal-aware start
                let candidates = self.updatableGames
                let skipped: [String: Any] = ["kept": self.updateSkips.kept, "noFiles": self.updateSkips.noFiles]
                guard !candidates.isEmpty else {
                    throw .conflict("No built game to bring up to date: each is kept, busy, or without its game files")
                }
                let waited = self.buildsWaitForPower
                self.buildsWaitForPower = args.bool("onlyWhilePluggedIn") ?? false
                let (started, refused) = self.controlStartAll(.extract, candidates)
                if started.isEmpty { self.buildsWaitForPower = waited }
                self.startNextExtraction()
                return try self.controlBulkAnswer("update", started: started, refused: refused, extra: ["skipped": skipped])
            },
            ControlCommand(
                "games.remove", "Remove the game for good (Remove Game…): its files, build, IPAs and Mac app; saves too only if asked",
                params: [game, ControlParam("removeSaves", .boolean, required: false, "Delete its saves as well (default false)"),
                         ControlParam("confirm", .string(maxLength: 512), "The game's id again, to confirm")],
                effect: .destructive
            ) { args throws(ControlError) in
                let id = args.string("game") ?? ""
                let target = try self.controlGame(id)
                guard args.string("confirm") == id else { throw .invalidArgs("confirm must be the game's id, \(id)") }
                guard self.canRemove(target) else { throw .conflict("\(target.name) is busy or still copying") }
                let failures = await self.remove(target, removingSaves: args.bool("removeSaves") ?? false)
                guard failures.isEmpty else { throw .failed("Not everything was removed: " + failures.joined(separator: "; ")) }
                return .value(["removed": id])
            },
        ]
    }

    private func settingsCommands() -> [ControlCommand] {
        [
            ControlCommand("settings.get", "NX Play's settings, without secrets (the pairing code is never shown)", effect: .read) { _ throws(ControlError) in
                .value(self.controlSettingsJSON())
            },
            ControlCommand(
                "settings.update", "Change settings: only the keys given, checked together and applied together, saved like the Settings window's",
                params: [ControlParam("patch", .object(Self.controlWritableSettings), "The settings to change")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let changed = try self.controlPatchSettings(args.object("patch") ?? [:])
                return .value(["changed": changed, "settings": self.controlSettingsJSON()])
            },
            ControlCommand("companion.status", "The iOS app's server: on or off, port, addresses, Bonjour, Tailscale (never its pairing code)", effect: .read) { _ throws(ControlError) in
                .value(self.controlCompanionJSON())
            },
        ]
    }

    private func sourceCommands() -> [ControlCommand] {
        let source = ControlParam("source", .string(maxLength: 128), "The source's id (sources.list)")
        let download = ControlParam("download", .string(maxLength: 128), "The download's id (downloads.list)")
        let repos = repositories
        return [
            ControlCommand("sources.list", "The Sources, each with its catalog's state and whether it has an access token", effect: .read) { _ throws(ControlError) in
                .value(repos.sources.map { source -> [String: Any] in
                    var json = self.remoteJSON(source)
                    json["path"] = source.url.path
                    json["token"] =
                        switch repos.tokenState(source.id) {
                        case .none: "none"
                        case .saved: "saved"
                        case .unreadable: "unreadable"
                        }
                    return json
                })
            },
            ControlCommand(
                "sources.add", "Add a source by its catalog's address (an access token is set in the Sources window, never here)",
                params: [ControlParam("url", .string(maxLength: 2048), "The catalog: https://server/catalog.json (plain http on the local network only)"),
                         ControlParam("name", .string(maxLength: 120), required: false, "A name (the host when left out)")],
                effect: .write
            ) { args throws(ControlError) in
                do {
                    let added = try repos.addSource(name: args.string("name") ?? "", address: args.string("url") ?? "")
                    return .value(self.remoteJSON(added))
                } catch let failure as Repositories.Failure {
                    throw .from(failure)
                } catch {
                    throw .failed(error.localizedDescription)
                }
            },
            ControlCommand(
                "sources.remove", "Remove a source, its access token and its waiting downloads (files already downloaded stay)",
                params: [source], effect: .destructive
            ) { args throws(ControlError) in
                let id = args.string("source") ?? ""
                guard repos.source(id) != nil else { throw .notFound("No source \(id)") }
                do {
                    try repos.removeSource(id)
                } catch let failure as Repositories.Failure {
                    throw .from(failure)
                } catch {
                    throw .failed(error.localizedDescription)
                }
                return .value(["removed": id])
            },
            ControlCommand(
                "sources.set_enabled", "Turn a source on or off", params: [source, ControlParam("enabled", .boolean, "On or off")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let id = args.string("source") ?? ""
                guard repos.source(id) != nil else { throw .notFound("No source \(id)") }
                repos.setEnabled(args.bool("enabled") ?? true, id)
                return .value(repos.source(id).map(self.remoteJSON) ?? [:])
            },
            ControlCommand(
                "sources.refresh", "Read one source's catalog again, or every source that's on",
                params: [ControlParam("source", .string(maxLength: 128), required: false, "One source's id; all when left out")],
                effect: .read, openWorld: true
            ) { args throws(ControlError) in
                if let id = args.string("source") {
                    guard let found = repos.source(id) else { throw .notFound("No source \(id)") }
                    guard found.enabled else { throw .conflict("\(found.name) is turned off") }
                    await repos.refresh(id)
                } else {
                    await repos.refreshAll()
                }
                return .value(repos.sources.map(self.remoteJSON))
            },
            ControlCommand(
                "sources.entries", "A source's games (or every loaded source's), with what's in the games folder already",
                params: [ControlParam("source", .string(maxLength: 128), required: false, "One source; all loaded ones when left out"),
                         ControlParam("query", .string(maxLength: 256), required: false, "Words the name, title ID or publisher must have")],
                effect: .read
            ) { args throws(ControlError) in
                let id = args.string("source")
                if let id {
                    guard let found = repos.source(id) else { throw .notFound("No source \(id)") }
                    guard found.enabled else { throw .conflict("\(found.name) is turned off") }
                    if case .failed(let message) = repos.states[id] { throw .failed(message, status: 502) }
                    guard repos.catalog(id) != nil else { throw .conflict("\(found.name) isn't loaded: sources.refresh it first") }
                }
                return .value(repos.entries(source: id, search: args.string("query") ?? "").map { row -> [String: Any] in
                    var json = self.remoteJSON(row.entry)
                    json["source"] = row.source.id
                    return json
                })
            },
            ControlCommand("downloads.list", "The downloads: running, waiting and finished", effect: .read) { _ throws(ControlError) in
                .value(repos.downloads.map(self.remoteJSON))
            },
            ControlCommand(
                "downloads.start", "Download a source's game into the games folder (Download): checked, then put in place whole",
                params: [source, ControlParam("entry", .string(maxLength: 256), "The entry's id (sources.entries)"),
                         ControlParam("packages", .array(.string(maxLength: 200), maxItems: 2000), required: false, "Package ids (all missing ones when left out)")],
                effect: .write, openWorld: true, cancel: "jobs cancel or downloads.cancel"
            ) { args throws(ControlError) in
                do {
                    let job = try repos.download(
                        source: args.string("source") ?? "", entry: args.string("entry") ?? "",
                        packages: args.strings("packages").map { Set($0.map { $0.lowercased() }) })
                    return .download(job.id, attempt: job.attempt, self.remoteJSON(job))
                } catch let failure as Repositories.Failure {
                    throw .from(failure)
                } catch {
                    throw .failed(error.localizedDescription)
                }
            },
            ControlCommand("downloads.cancel", "Stop a download or take it off the queue (its partial file is deleted)", params: [download], effect: .write, idempotent: true) { args throws(ControlError) in
                let id = args.string("download") ?? ""
                guard repos.job(id) != nil else { throw .notFound("No download \(id)") }
                repos.cancel(id)
                self.controlHub?.updateAll()
                return .value(repos.job(id).map(self.remoteJSON) ?? [:])
            },
            ControlCommand(
                "downloads.retry", "Start a failed or cancelled download again (files it already put in place count as done)",
                params: [download], effect: .write, openWorld: true, cancel: "jobs cancel or downloads.cancel"
            ) { args throws(ControlError) in
                let id = args.string("download") ?? ""
                do {
                    // a new run of the id: a job that followed an earlier run still follows that one (DownloadJob.attempt)
                    let job = try repos.retry(id)
                    return .download(job.id, attempt: job.attempt, self.remoteJSON(job))
                } catch let failure as Repositories.Failure {
                    throw .from(failure)
                } catch {
                    throw .failed(error.localizedDescription)
                }
            },
        ]
    }

    private func deviceCommands() -> [ControlCommand] {
        [
            ControlCommand(
                "devices.list", "The iPhones and iPads an install can go to, and Xcode's teams",
                params: [ControlParam("refresh", .boolean, required: false, "Ask devicectl again first (a few seconds)")], effect: .read, openWorld: true
            ) { args throws(ControlError) in
                if args.bool("refresh") == true, !self.isScreenshot {
                    self.teams = AppleTeam.fromXcode()
                    self.devices = await Device.load()
                }
                return .value([
                    "devices": self.devices.map(self.remoteJSON),
                    "teams": self.teams.map { ["id": $0.id, "name": $0.name, "free": $0.isFree] },
                    "team": self.team?.id as Any,
                ])
            },
            ControlCommand(
                "ios_app.install", "Install NX Play for iPhone and iPad on a device (Settings › Devices › Install NX Play)",
                params: [ControlParam("device", .string(maxLength: 128), "The device's UDID (devices.list)")], effect: .write, openWorld: true
            ) { args throws(ControlError) in
                guard self.canInstallIOSApp else { throw .conflict("This copy of NX Play doesn't have the iOS app's source") }
                guard self.iosAppInstall?.state != .running else { throw .conflict("An install of NX Play is running already") }
                let udid = args.string("device") ?? ""
                guard let device = self.devices.first(where: { $0.id == udid }) else { throw .notFound("No device \(udid): devices.list with refresh") }
                self.installIOSApp(on: device)
                guard let install = self.iosAppInstall, install.device == device else { throw .failed("The install didn't start") }
                return .iosApp(install.id, ["device": udid, "status": install.status, "started": install.started])
            },
        ]
    }

    private func cleanupCommands() -> [ControlCommand] {
        [
            ControlCommand(
                "cleanup.scan", "What Free Up Space can delete, game by game: game files, builds, IPAs, Xcode builds, Mac apps",
                params: [ControlParam("measure", .boolean, required: false, "Measure the big folders too (slow: every file in a build)")], effect: .read
            ) { args throws(ControlError) in
                let busy = Set(self.games.filter { self.isBusy($0) || self.isReserved($0) }.map(\.id))
                let games = self.games
                let measure = args.bool("measure") ?? false
                let groups = await Task.detached { CleanupScanner.groups(games: games, busy: busy, measuring: measure) }.value
                return .value(["phrase": Cleanup.phrase, "groups": self.controlCleanupJSON(groups)])
            },
            ControlCommand(
                "cleanup.delete", "Delete the given files and folders for good (Free Up Space › Delete), with its rules: never a game's build and its game files together",
                params: [ControlParam("paths", .array(.string(maxLength: 2048), maxItems: 500), "Paths exactly as cleanup.scan lists them"),
                         ControlParam("confirm", .string(maxLength: 64), "The phrase cleanup.scan gives: yes, I'm sure")],
                effect: .destructive
            ) { args throws(ControlError) in
                let paths = args.strings("paths") ?? []
                guard !paths.isEmpty else { throw .invalidArgs("paths is empty") }
                guard Cleanup.normalized(args.string("confirm") ?? "") == Cleanup.normalized(Cleanup.phrase) else {
                    throw .invalidArgs("confirm must be the phrase “\(Cleanup.phrase)”")
                }
                if let relative = paths.first(where: { !$0.hasPrefix("/") }) {
                    throw .invalidArgs("\(relative) isn't an absolute path")
                }
                // the window's Delete: the library's turn for file work, the games held, and the selection judged
                // again from the disk as it is then (Library+FileWork.swift)
                switch await self.freeUpSpace(paths.map { URL(filePath: $0) }) {
                case .done(let removed, let size):
                    return .value(["deleted": removed.map(\.path), "count": removed.count, "bytes": size])
                case .refused(let message): throw .conflict(message)
                case .notListed(let message): throw .notFound(message)
                case .failed(let message, _, _): throw .failed(message)
                }
            },
        ]
    }

    private func uiCommands() -> [ControlCommand] {
        [
            ControlCommand("ui.state", "What the window shows: selection, search, Console Mode, open questions and sheets", effect: .read) { _ throws(ControlError) in
                .value(self.controlUIJSON())
            },
            ControlCommand(
                "ui.select", "Select a game in the window, or nothing",
                params: [ControlParam("game", .nullable(.string(maxLength: 512)), "The game's id, or null")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                if let id = args.string("game") {
                    self.selection = try self.controlGame(id).id
                } else {
                    self.selection = nil
                }
                return .value(["selection": self.selectedGame?.folder.lastPathComponent as Any])
            },
            ControlCommand(
                "ui.search", "Set the library's search field", params: [ControlParam("text", .string(maxLength: 256), "Empty shows every game")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                self.search = args.string("text") ?? ""
                return .value(["search": self.search, "shown": self.shownGames.count])
            },
            ControlCommand(
                "ui.console_mode", "Turn Console Mode on or off", params: [ControlParam("on", .boolean, "On or off")], effect: .write, idempotent: true
            ) { args throws(ControlError) in
                self.consoleMode = args.bool("on") ?? false
                return .value(["consoleMode": self.consoleMode])
            },
            ControlCommand(
                "ui.open", "Bring NX Play forward and open one of its windows",
                params: [ControlParam("window", .string(choices: ControlWindow.allCases.map(\.rawValue)), "Which window"),
                         ControlParam("tab", .string(choices: ["general", "games", "saves", "devices", "updates"]), required: false, "Settings' tab")],
                effect: .write, idempotent: true
            ) { args throws(ControlError) in
                let window = ControlWindow(rawValue: args.string("window") ?? "") ?? .main
                if let tab = args.string("tab") {
                    self.settingsTab = ["general": .general, "games": .games, "saves": .saves, "devices": .devices, "updates": .updates][tab] ?? .general
                }
                let opened = await self.controlOpen(window)
                return .value(["window": window.rawValue, "opened": opened])
            },
        ]
    }
}

/// The windows `ui.open` opens; RootView opens them (only a SwiftUI view can).
public enum ControlWindow: String, CaseIterable, Sendable {
    case main, sources, freeUpSpace = "free_up_space", setup, settings, changelog, controls

    @MainActor public var windowID: String? {
        switch self {
        case .main: nil
        case .sources: SourcesView.windowID
        case .freeUpSpace: CleanupView.windowID
        case .setup: SetupView.windowID
        case .settings: nil
        case .changelog: ChangelogView.windowID
        case .controls: ControlsView.windowID
        }
    }
}

/// A window `ui.open` asked for: each request a serial of its own, which RootView answers for that request alone.
public struct ControlWindowRequest: Equatable, Sendable {
    public let window: ControlWindow
    public let serial: Int
}
