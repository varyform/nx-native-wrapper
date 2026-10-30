import Foundation

/// Game › Remove Game…: the game's files, build, IPAs and Mac app deleted for good, its saves kept unless asked.
extension Library {
    /// Whether the game can be removed now: not while it builds or plays.
    public func canRemove(_ game: Game) -> Bool { !isBusy(game) && !game.isCopying }

    /// Removes it and reads the library again. → what couldn't be deleted (empty when all went).
    @discardableResult
    public func remove(_ game: Game, removingSaves: Bool) async -> [String] {
        guard canRemove(game) else { return ["\(game.name) is busy: stop it first."] }
        let removal = GameRemoval(game: game, removesSaves: removingSaves)
        var failures: [String] = []
        await inFlight {
            failures = await Task.detached { removal.perform() }.value
        }
        if selection == game.id { selection = nil }
        jobs[game.id] = nil
        refresh()
        return failures
    }
}
