import Foundation

/// The games built already whose NSZ or XCZ can give way to the unpacked copy, and what that frees.
public struct UnpackedSweep: Identifiable, Sendable {
    public let id = UUID()
    public let games: Int
    public let files: Int
    public let size: Int64
}

/// Keep Only the Unpacked Copy: nxnative unpacks an NSZ or XCZ into the build folder and keeps both, and a rebuild
/// without the build folder unpacks it again. Once a game is built for the Mac, which proves the unpacked file
/// whole, it takes the compressed file's place in the game folder and the compressed one goes to the Trash.
extension Library {
    /// After a successful job: the game's files, if it's built and nothing else is running for it. Renames on one
    /// volume, so done at once, before the next queued build can start on the game.
    func keepUnpacked(of id: Game.ID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        let failures = swapUnpacked(of: [game])
        if !failures.isEmpty { problem = failureText(failures) }
    }

    /// When the setting is turned on: what the games built already would free, to ask about it (nothing to ask
    /// when there's nothing to tidy).
    func offerUnpackedSweep() {
        let pairs = candidates(games).flatMap(\.pairs)
        guard !pairs.isEmpty else { return }
        unpackedSweep = UnpackedSweep(
            games: Set(pairs.map { $0.compressed.deletingLastPathComponent() }).count, files: pairs.count,
            size: pairs.reduce(0) { $0 + $1.size })
    }

    /// The sweep, confirmed: the games as they are now, as one may have started building since it was offered.
    public func sweepUnpacked() {
        unpackedSweep = nil
        let failures = swapUnpacked(of: games)
        if !failures.isEmpty { problem = failureText(failures) }
    }

    private func candidates(_ games: [Game]) -> [(game: Game, pairs: [CompressedPackages.Pair])] {
        games
            .filter { $0.state == .ready && !$0.isCopying && !isBusy($0) }
            .map { ($0, CompressedPackages.pairs(of: $0)) }
            .filter { !$0.pairs.isEmpty }
    }

    /// The swaps, one file at a time: a failed one leaves that file as it was and the rest go on.
    private func swapUnpacked(of games: [Game]) -> [String] {
        var failures: [String] = []
        var swapped = false
        for (_, pairs) in candidates(games) {
            for pair in pairs {
                do {
                    try CompressedPackages.swap(pair)
                    swapped = true
                } catch {
                    failures.append("\(pair.compressed.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if swapped { refresh() }
        return failures
    }

    private func failureText(_ failures: [String]) -> String {
        "These compressed files stay where they are, beside the build's unpacked copy:\n\n"
            + failures.joined(separator: "\n")
    }
}
