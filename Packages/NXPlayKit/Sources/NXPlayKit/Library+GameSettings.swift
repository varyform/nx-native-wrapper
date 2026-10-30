import Foundation

/// Game settings in two layers: global values for every game that offers them (Settings › Games, kept in NX Play) and
/// a game's own over them (Game › Game Settings…, kept in nxnative's store, which the game's Mac app shares). A play
/// passes the result in the game's environment. Each game's list comes from nxplay (nxplay-settings.json).
extension Library {
    // MARK: - Values

    /// The game's value for a setting: its own, else the global one, else its tested default.
    public func value(_ setting: LauncherSetting, for game: Game) -> String {
        own(setting, for: game) ?? globalValue(setting, for: game) ?? setting.defaultValue
    }

    /// The game's own value, when it has one this build offers.
    public func own(_ setting: LauncherSetting, for game: Game) -> String? {
        _ = choicesRevision
        return choices(for: game)?.value(for: setting)
    }

    /// The global value this game gets, nil when there's none it offers. The language follows NX Play's rule: the same
    /// language for another region when the game lacks the one asked for.
    public func globalValue(_ setting: LauncherSetting, for game: Game) -> String? {
        guard let value = globalChoices[setting.env] else { return nil }
        if setting.env == "DM_LANG", let near = GameLanguage.choose(value, for: game),
            setting.accepts(near)
        {
            return near
        }
        return setting.accepts(value) ? value : nil
    }

    /// A game's own value, or nil to follow the global one again.
    public func setOwn(_ value: String?, _ setting: LauncherSetting, for game: Game) {
        guard let choices = choices(for: game) else { return }
        choices.set(value.flatMap { setting.accepts($0) ? $0 : nil }, for: setting.env)
        choicesRevision += 1
    }

    /// Use Global Settings: the game follows every global value again (its list's keys removed, as the Mac app's
    /// Reset to tested defaults does).
    public func clearOwn(_ settings: LauncherSettings, for game: Game) {
        guard let choices = choices(for: game) else { return }
        settings.settings.forEach { choices.set(nil, for: $0.env) }
        choicesRevision += 1
    }

    /// A global value, or nil for each game's own default.
    public func setGlobal(_ value: String?, for env: String) {
        globalChoices[env] = value
    }

    /// The environment a play passes: every setting the game's list has, at its value when that isn't the tested
    /// default (the host has those already). Without a list, the global language, display mode and HUD, as before
    /// the lists.
    func playEnvironment(for game: Game) -> [String: String] {
        guard let list = settingsLists[game.id] ?? gameSettings(for: game) else {
            var environment: [String: String] = [:]
            environment["DM_LANG"] = GameLanguage.choose(language, for: game)
            for env in ["DM_FULLSCREEN", "DM_METAL_HUD"] { environment[env] = globalChoices[env] }
            return environment
        }
        var environment: [String: String] = [:]
        for setting in list.settings {
            let value = value(setting, for: game)
            if !setting.same(value, setting.defaultValue) { environment[setting.env] = value }
        }
        return environment
    }

    // MARK: - Settings › Games

    /// One row per setting the games' lists have, the first game's row with the options of all of them; the language
    /// lists every language NX Play knows. Language, display mode and the HUD are there before any game has a list.
    public var globalSettings: [LauncherSetting] {
        var rows: [LauncherSetting] = []
        for setting in games.compactMap({ settingsLists[$0.id] }).flatMap(\.settings) {
            guard let index = rows.firstIndex(where: { $0.env == setting.env }) else {
                rows.append(setting)
                continue
            }
            rows[index] = Self.merged(rows[index], setting)
        }
        for fallback in Self.fallbackSettings
        where !rows.contains(where: { $0.env == fallback.env }) {
            rows.append(fallback)
        }
        return rows.map { row in
            guard row.env == "DM_LANG" else { return row }
            return LauncherSetting(
                env: row.env,
                kind: .choice(GameLanguage.all.map { .init(value: $0.code, label: $0.name) }),
                section: row.section, label: row.label, note: row.note,
                defaultValue: row.defaultValue, isBasic: row.isBasic, needs: row.needs)
        }
    }

    /// The default every game shares for a setting, nil when they differ (or there's none, as the language): what
    /// Settings › Games shows while nothing is set.
    public func sharedDefault(for env: String) -> String? {
        let rows = games.compactMap { settingsLists[$0.id]?[env] }
        guard let first = rows.first else {
            return Self.fallbackSettings.first { $0.env == env }.map(\.defaultValue)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        return rows.allSatisfy({ first.same($0.defaultValue, first.defaultValue) })
            ? first.defaultValue : nil
    }

    /// The same setting in two games: a choice offers what either does, a range spans both.
    private static func merged(_ a: LauncherSetting, _ b: LauncherSetting) -> LauncherSetting {
        let kind: LauncherSetting.Kind
        switch (a.kind, b.kind) {
        case (.choice(let x), .choice(let y)): kind = .choice(x + y.filter { !x.contains($0) })
        case (.range(let lo, let hi, let step), .range(let lo2, let hi2, _)):
            kind = .range(min: min(lo, lo2), max: max(hi, hi2), step: step)
        default: kind = a.kind
        }
        return LauncherSetting(
            env: a.env, kind: kind, section: a.section, label: a.label, note: a.note,
            defaultValue: a.defaultValue, isBasic: a.isBasic, needs: a.needs)
    }

    /// Language, display mode and the HUD, as nxnative's settings.tsv words them: NX Play's settings before the lists.
    static let fallbackSettings: [LauncherSetting] = [
        LauncherSetting(
            env: "DM_LANG", kind: .choice([]), section: "Game", label: "Game language", note: "",
            defaultValue: "", isBasic: true, needs: nil),
        LauncherSetting(
            env: "DM_FULLSCREEN",
            kind: .choice([
                .init(value: "0", label: "Window"), .init(value: "1", label: "Fullscreen"),
            ]),
            section: "Game", label: "Display mode", note: "", defaultValue: "0", isBasic: true,
            needs: nil),
        LauncherSetting(
            env: "DM_METAL_HUD", kind: .toggle(on: "1", off: "0"), section: "Performance",
            label: "Performance HUD", note: "", defaultValue: "0", isBasic: false, needs: nil),
    ]

    /// The global values as saved; the first time, the three settings NX Play had before become global values.
    static func loadGlobalChoices(_ defaults: UserDefaults) -> [String: String] {
        if let global = defaults.dictionary(forKey: Keys.globalSettings) as? [String: String] {
            return global
        }
        var global: [String: String] = [:]
        if let language = defaults.string(forKey: Keys.language), !language.isEmpty {
            global["DM_LANG"] = language
        }
        if defaults.bool(forKey: Keys.metalHUD) { global["DM_METAL_HUD"] = "1" }
        if defaults.bool(forKey: Keys.fullScreenGames) { global["DM_FULLSCREEN"] = "1" }
        return global
    }

    // MARK: - Lists

    /// The list nxplay wrote for the game; nil before its first build.
    public func gameSettings(for game: Game) -> LauncherSettings? {
        settingsFile(for: game).flatMap(LauncherSettings.read)
    }

    func readSettingsLists() {
        settingsLists = Dictionary(
            games.compactMap { game in gameSettings(for: game).map { (game.id, $0) } },
            uniquingKeysWith: { a, _ in a })
    }

    /// The list, written first when it's missing or older than the launcher (a rebuild may change it): nxplay
    /// --settings, a second or so of Python, off the main thread.
    public func loadGameSettings(for game: Game) async -> LauncherSettings? {
        await writeSettingsLists(for: [game])
        return settingsLists[game.id]
    }

    /// Writes the lists the built games lack (or have older than their launcher), one game after another, in the
    /// background; Settings › Games then has every game's settings. Each game once a launch: a build or a play writes
    /// its list after that.
    func writeMissingSettingsLists() {
        guard !isScreenshot else { return }
        let built = games.filter { $0.state == .ready && !settingsListsTried.contains($0.id) }
        guard !built.isEmpty else { return }
        settingsListsTried.formUnion(built.map(\.id))
        Task { await writeSettingsLists(for: built) }
    }

    private func writeSettingsLists(for games: [Game]) async {
        let stale = games.filter { game in
            guard let file = settingsFile(for: game),
                let launcher = game.buildFolder?.appending(path: GameScanner.launcherName)
            else { return false }
            return game.state == .ready && !Self.isNewer(file, than: launcher)
        }
        guard !stale.isEmpty, let script = AppHome.script else { return }
        let environment = NXPlayCommand.environment(
            nxnative: (nxnativePath as NSString).expandingTildeInPath,
            keys: (keysPath as NSString).expandingTildeInPath, venv: AppHome.venv.path)
        let folders = stale.map(\.folder.path)
        await Task.detached {
            for folder in folders {
                Self.runQuietly(script, ["--settings", folder], environment: environment)
            }
        }.value
        readSettingsLists()
    }

    private func choices(for game: Game) -> SavedChoices? {
        game.titleID.flatMap { choicesStore(SavedChoices.domain(titleID: $0)) }.map(
            SavedChoices.init)
    }

    private func settingsFile(for game: Game) -> URL? {
        game.buildFolder?.appending(path: LauncherSettings.fileName)
    }

    private static func isNewer(_ file: URL, than other: URL) -> Bool {
        func date(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        guard let mine = date(file) else { return false }
        return date(other).map { mine >= $0 } ?? true
    }

    nonisolated private static func runQuietly(
        _ script: URL, _ arguments: [String], environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
