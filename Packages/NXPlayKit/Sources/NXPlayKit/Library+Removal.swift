import Foundation

/// Game › Remove Game…: the game's files, build, IPAs and Mac app deleted for good, its saves kept unless asked.
extension Library {
    /// Whether the game can be removed now: not while it builds or plays, or while file work holds it.
    public func canRemove(_ game: Game) -> Bool { !isBusy(game) && !game.isCopying && !isReserved(game) }

    /// Removes it and reads the library again. → what couldn't be deleted (empty when all went). File work
    /// (Library+FileWork.swift): after any deletion before it, with the game held, and judged again from the disk
    /// as it is then, so the window and the control API can't remove it while a build starts or cleanup deletes.
    @discardableResult
    public func remove(_ game: Game, removingSaves: Bool) async -> [String] {
        guard canRemove(game) else { return ["\(game.name) is busy: stop it first."] }
        return await fileWork(holding: [game.id]) { () async -> [String] in
            refresh()
            guard let current = games.first(where: { $0.id == game.id }) else {
                return ["\(game.name) isn't in the games folder any more."]
            }
            guard !isBusy(current), !current.isCopying else { return ["\(game.name) is busy: stop it first."] }
            let removal = GameRemoval(game: current, removesSaves: removingSaves)
            let failures = await Task.detached { removal.perform() }.value
            if selection == game.id { selection = nil }
            jobs[game.id] = nil
            refresh()
            return failures
        }
    }
}
