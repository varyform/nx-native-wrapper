import Foundation

/// What Play does when nxnative has new code for a game built with older code (nxplay's NXPLAY_UPDATE): ask, pull it
/// and rebuild first, or play the build as it is.
public enum UpdateBeforePlay: String, CaseIterable, Sendable {
    case ask, update, current
}

/// The player's answer to nxplay's question, written to its stdin.
public enum UpdateAnswer: String, Sendable {
    case update, current, cancel
}

/// nxplay's question before a play (its JSON `ask` event, NXPLAY_UPDATE=ask): what new nxnative code would mean for
/// the game's build. Read field by field like the build's events: a field missing or odd is left out, never guessed.
public struct UpdateAsk: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public let hash: String
        public let subject: String
    }

    /// What happens to the shaders: all translated again (the shader chain changed), checked again (their tools
    /// or the game's profile changed), reused, or unknown (the build's code is gone from the checkout).
    public enum Shaders: String, Sendable {
        case recompile, check, reused, unknown
    }

    /// New commits since the build's code; nil when unknown.
    public let commits: Int?
    /// The ones that change the game's own profile (dm/games/<title ID>).
    public let gameCommits: [Commit]
    public let shaders: Shaders
    /// The last update's rebuild, with the Mac app's repack when it has one; nil before one was timed.
    public let estimate: TimeInterval?
    public let hasApp: Bool

    public init(
        commits: Int?, gameCommits: [Commit], shaders: Shaders, estimate: TimeInterval?,
        hasApp: Bool
    ) {
        self.commits = commits
        self.gameCommits = gameCommits
        self.shaders = shaders
        self.estimate = estimate
        self.hasApp = hasApp
    }

    init?(event: [String: Any]) {
        guard event["about"] as? String == "update" else { return nil }
        let count = (event["commits"] as? NSNumber)?.intValue
        commits = count.flatMap { $0 >= 0 && $0 < 1_000_000 ? $0 : nil }
        gameCommits = ((event["game"] as? [Any]) ?? []).compactMap {
            guard let commit = $0 as? [String: Any], let hash = commit["hash"] as? String,
                let subject = commit["subject"] as? String
            else { return nil }
            return Commit(hash: hash, subject: subject)
        }
        shaders = (event["shaders"] as? String).flatMap(Shaders.init(rawValue:)) ?? .unknown
        estimate = (event["estimate"] as? NSNumber).map(\.doubleValue).flatMap {
            $0 > 0 && $0 < 1e6 ? $0 : nil
        }
        hasApp = event["app"] as? Bool ?? false
    }

    /// "79 new nxnative commits, none for this game"
    public var headline: String {
        let mine = gameCommits.isEmpty ? "none" : "\(gameCommits.count)"
        guard let commits else { return "New nxnative code, \(mine) of it for this game" }
        return "\(commits) new nxnative commit\(commits == 1 ? "" : "s"), \(mine) for this game"
    }

    public var shadersText: String {
        switch shaders {
        case .recompile: "Every shader is translated again: the shader chain changed."
        case .check: "Shaders are checked again; some may be translated again."
        case .reused: "Shaders are reused."
        case .unknown: "Whether the shaders change can't be told."
        }
    }

    /// "About 12 min, as last time (the Mac app included)"; nil before an update was timed.
    public var estimateText: String? {
        estimate.map {
            "About \(max(1, Int(($0 / 60).rounded(.up)))) min, as last time\(hasApp ? " (the Mac app included)" : "")"
        }
    }

    /// The line the log shows for the question.
    var logLine: String {
        "nxplay: \(headline). \(shadersText) Asking whether to update first."
    }
}
