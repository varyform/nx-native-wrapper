import Foundation

/// A game's mods in Game Settings, and the play that loads them (Model/GameMods.swift).
extension Library {
    public func modsFolder(for game: Game) -> URL { GameMods.folder(of: game) }

    /// The mods as they are now, then their files counted off the main thread (a mod can hold thousands).
    public func loadMods(for game: Game) async {
        let folder = GameMods.folder(of: game), titleID = game.titleID
        let mods = await Task.detached { GameMods.scan(folder, titleID: titleID) }.value
        gameMods[game.id] = mods
        await countModFiles(for: game, mods)
    }

    /// Changes in the game's Mods folder, made too, but not NX Play's own order file.
    func modsChanges(for game: Game) -> AsyncStream<Void> {
        FolderWatch.changes(in: GameMods.folder(of: game), root: game.folder, ignoring: [GameMods.orderFile])
    }

    public func setMod(_ name: String, on: Bool, for game: Game) {
        guard var mods = gameMods[game.id], let index = mods.firstIndex(where: { $0.name == name }) else { return }
        mods[index].isOn = on
        saveMods(mods, for: game)
    }

    /// Moves a mod before another, or to the end with nil: the first mod wins a file two of them change.
    public func moveMod(_ name: String, before target: String?, for game: Game) {
        guard var mods = gameMods[game.id], name != target,
            let from = mods.firstIndex(where: { $0.name == name })
        else { return }
        let mod = mods.remove(at: from)
        let to = target.flatMap { target in mods.firstIndex { $0.name == target } } ?? mods.endIndex
        mods.insert(mod, at: to)
        saveMods(mods, for: game)
    }

    private func saveMods(_ mods: [GameMod], for game: Game) {
        gameMods[game.id] = mods
        do {
            try GameMods.save(mods, in: GameMods.folder(of: game))
        } catch {
            problem = "The mods' order couldn't be saved: \(error.localizedDescription)"
        }
        Task { await countModFiles(for: game, mods) }
    }

    private func countModFiles(for game: Game, _ mods: [GameMod]) async {
        let files = await Task.detached { GameMods.files(mods) }.value
        // a later change counts again; only the latest list's counts are kept
        guard gameMods[game.id] == mods else { return }
        modFiles[game.id] = files
    }

    /// DM_ROMFS_OVERLAY for a play of a game with a Mods folder, "" with none on, which also overrides an older
    /// value in its Mac app's env.txt (nxplay's share_save writes it there for a start from Finder); NXPLAY_MODS for
    /// the log: the mods loading, and those that don't although on.
    func modsEnvironment(for game: Game) -> [String: String] {
        let folder = GameMods.folder(of: game)
        guard GameScanner.isDirectory(folder) else { return [:] }
        let mods = GameMods.scan(folder, titleID: game.titleID)
        let overlay = GameMods.overlay(mods)
        var said = overlay.loaded.map(\.name)
        for mod in mods where mod.isOn {
            switch mod.problem {
            case .noRomFS: said.append("\(mod.name) (left out: no romfs folder)")
            case .colonInPath: said.append("\(mod.name) (left out: a colon in its path)")
            case nil:
                if overlay.tooLong.contains(mod) { said.append("\(mod.name) (left out: too many mods)") }
            }
        }
        return ["DM_ROMFS_OVERLAY": overlay.value, "NXPLAY_MODS": said.isEmpty ? "none" : said.joined(separator: ", ")]
    }
}
