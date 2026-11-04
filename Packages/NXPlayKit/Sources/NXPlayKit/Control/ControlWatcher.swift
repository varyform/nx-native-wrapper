import Foundation
import Observation

/// Turns the library's changes into the API's events, whoever made them (the window, the controller, the iOS app, a
/// call): it reads a small picture of the library under Observation, and on each change compares it with the last.
/// Builds' progress is reported in whole percents, so a chatty build doesn't flood the log. What it hands `hub.emit`
/// is live text (a search, a download's message, a build's text, an install's status): the hub keeps it scrubbed.
@MainActor final class ControlWatcher {
    private unowned let library: Library
    private unowned let hub: ControlHub
    private var last: Picture?
    private var active = false

    init(library: Library, hub: ControlHub) {
        self.library = library
        self.hub = hub
    }

    func start() {
        active = true
        track()
    }

    func stop() { active = false }

    private func track() {
        guard active else { return }
        let picture = withObservationTracking {
            Picture(library)
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        if let last { compare(last, picture) }
        last = picture
    }

    private func changed() {
        guard active else { return }
        track()
        hub.updateAll()
    }

    struct Build: Equatable {
        let job: UUID
        let kind: String
        let status: String
        let percent: Int
        let asking: Bool
    }

    struct Download: Equatable {
        let state: String
        let percent: Int
        let message: String?
    }

    struct Picture: Equatable {
        var root: String?
        var games: [String: String] = [:]
        var builds: [String: Build] = [:]
        var downloads: [String: Download] = [:]
        var sources: [String: String] = [:]
        var settings: [String: String] = [:]
        var ui: [String: String] = [:]
        /// Install NX Play's run: which, how it's going, how it ended (from Settings or a call alike).
        var iosApp: IOSApp?

        struct IOSApp: Equatable {
            let id: UUID
            let device: String
            let state: String
            let status: String
        }

        @MainActor init(_ library: Library) {
            root = library.root?.path
            for game in library.games {
                games[game.folder.lastPathComponent] = "\(game.state)|\(game.isKept)|\(game.isCopying)|\(game.hasPackages)"
            }
            for job in library.jobs.values {
                var status = "\(job.status)"
                if case .failed = job.status { status = "failed" }
                builds[job.game.folder.lastPathComponent] = Build(
                    job: job.id, kind: Self.kind(job.kind), status: status,
                    percent: Int((job.progressFraction * 100).rounded()), asking: job.ask != nil)
            }
            for download in library.repositories.downloads {
                downloads[download.id] = Download(
                    state: download.state.rawValue, percent: Int((download.fraction * 100).rounded()),
                    message: download.message)
            }
            for source in library.repositories.sources {
                let state: String =
                    switch library.repositories.states[source.id] ?? .notLoaded {
                    case .notLoaded: "notLoaded"
                    case .loading: "loading"
                    case .loaded(let catalog, _): "loaded:\(catalog.entries.count)"
                    case .failed: "failed"
                    }
                sources[source.id] = "\(source.enabled)|\(state)|\(source.name)"
            }
            for (key, value) in library.controlSettingsJSON() where key != "keysFileExists" {
                settings[key] = ControlJSON.text(value)
            }
            iosApp = library.iosAppInstall.map {
                IOSApp(id: $0.id, device: $0.device.id, state: "\($0.state)", status: $0.status)
            }
            ui = [
                "selection": library.selection.map { URL(filePath: $0).lastPathComponent } ?? "",
                "search": library.search, "consoleMode": "\(library.consoleMode)",
                "updateQuestion": library.updatePrompt?.job.game.folder.lastPathComponent ?? "",
                "saveQuestion": library.saveQuestion?.game.folder.lastPathComponent ?? "",
                "settingsTab": "\(library.settingsTab)",
            ]
        }

        static func kind(_ kind: Job.Kind) -> String {
            if case .install = kind { return "install" }
            return "\(kind)"
        }
    }

    private func compare(_ old: Picture, _ new: Picture) {
        if old.root != new.root || old.games != new.games {
            let before = Set(old.games.keys)
            let after = Set(new.games.keys)
            hub.emit("library", [
                "gamesFolder": new.root ?? NSNull(), "games": new.games.count,
                "added": after.subtracting(before).sorted(), "removed": before.subtracting(after).sorted(),
                "changed": after.intersection(before).filter { old.games[$0] != new.games[$0] }.sorted(),
            ])
        }
        for (game, build) in new.builds where old.builds[game] != build {
            var data: [String: Any] = [
                "game": game, "kind": build.kind, "status": build.status, "fraction": Double(build.percent) / 100,
            ]
            if let job = library.jobs.values.first(where: { $0.id == build.job }) {
                data["text"] = job.progressText
                if case .failed(let code) = job.status { data["exitCode"] = Int(code) }
            }
            if build.asking != (old.builds[game]?.job == build.job && old.builds[game]?.asking == true) {
                data["question"] = build.asking ? "update" : NSNull()
            }
            hub.emit("build", data)
        }
        for (id, download) in new.downloads where old.downloads[id] != download {
            let job = library.repositories.job(id)
            hub.emit("download", [
                "download": id, "entry": job?.entryName ?? "", "state": download.state,
                "fraction": Double(download.percent) / 100, "message": download.message ?? NSNull(),
            ])
        }
        for (id, state) in new.sources where old.sources[id] != state {
            let parts = state.split(separator: "|", maxSplits: 2).map(String.init)
            hub.emit("sources", ["source": id, "enabled": parts.first == "true", "state": parts.count > 1 ? parts[1] : ""])
        }
        for id in Set(old.sources.keys).subtracting(new.sources.keys) {
            hub.emit("sources", ["source": id, "removed": true])
        }
        let settings = Set(old.settings.keys).union(new.settings.keys).filter { old.settings[$0] != new.settings[$0] }
        if !settings.isEmpty { hub.emit("settings", ["changed": settings.sorted()]) }
        if let install = new.iosApp, install != old.iosApp {
            hub.emit("ios_app", ["device": install.device, "state": install.state, "status": install.status])
        }
        let ui = Set(new.ui.keys).filter { old.ui[$0] != new.ui[$0] }
        if !ui.isEmpty {
            var data: [String: Any] = ["changed": ui.sorted()]
            for key in ui { data[key] = new.ui[key] ?? "" }
            hub.emit("ui", data)
        }
    }
}
