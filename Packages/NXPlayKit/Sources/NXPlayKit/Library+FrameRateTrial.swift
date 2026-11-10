import AppKit

/// 60 or 120 fps for a game nxnative has no profile for. nxnative lists **Frame rate** only for a game its profile has a
/// tested one for; a game without a profile, packed from the provisional one the NSP script makes, runs at the rate it
/// asks for, often 30. A game with a profile but no Frame rate runs at the rate nxnative tested, often 60 already
/// (Streets of Rage 4), and one that counts frames would only run too fast, so it gets none. Display mode (`DM_PRESENT_INTERVAL=display`) shows a frame each display refresh whatever
/// interval the game sets. That is right for a game that steps its logic by the time passed (Red Dead Redemption,
/// Wreckfest), and twice as fast for one that steps a fixed 1/30 s each frame, which only playing the game tells. So
/// it's a game's own choice in NX Play, off until the player turns it on, never a global value, and kept in NX Play
/// rather than in nxnative's store, whose Mac app doesn't know it.
extension Library {
    static let frameRateTrial = "NXPLAY_FRAME_RATE"

    /// 120 only where a screen shows it: on a 60 Hz one it would play at 60 anyway.
    static var frameRateTrialSetting: LauncherSetting {
        frameRateTrialSetting(offers120: NSScreen.screens.contains { $0.maximumFramesPerSecond >= 120 })
    }

    static func frameRateTrialSetting(offers120: Bool) -> LauncherSetting {
        LauncherSetting(
            env: frameRateTrial,
            kind: .choice(
                [.init(value: "0", label: "Game's own"), .init(value: "60", label: "60 fps")]
                    + (offers120 ? [.init(value: "120", label: "120 fps")] : [])),
            section: "Game", label: "Frame rate (untested)",
            note:
                "This game's build sets no frame rate. A frame each display refresh: right for a game that keeps time by the clock, too fast for one that counts frames. Time a race or a walk to tell.",
            defaultValue: "0", isBasic: true, needs: nil)
    }

    /// The list with NX Play's row, when the build has no Frame rate of its own (the caller leaves out the games
    /// nxnative has a profile for).
    static func withFrameRateTrial(_ list: LauncherSettings) -> LauncherSettings {
        guard list["DM_FPS_TARGET"] == nil, list[frameRateTrial] == nil else { return list }
        return LauncherSettings(titleID: list.titleID, settings: list.settings + [frameRateTrialSetting])
    }

    /// Each game's rate by title ID.
    var frameRateTrials: [String: String] {
        _ = choicesRevision
        return defaults.dictionary(forKey: Keys.frameRateTrials) as? [String: String] ?? [:]
    }

    /// The game's rate while the row still offers it (120 after a move to a 60 Hz screen is none).
    func frameRateTrial(for game: Game, in setting: LauncherSetting) -> String? {
        guard let id = game.titleID?.uppercased(), let rate = frameRateTrials[id] else { return nil }
        return setting.accepts(rate) ? rate : nil
    }

    /// A rate, or nil (and the game's own) to play at the game's own again.
    func setFrameRateTrial(_ rate: String?, for game: Game) {
        guard let id = game.titleID?.uppercased() else { return }
        var trials = frameRateTrials
        trials[id] = rate == "0" ? nil : rate
        defaults.set(trials, forKey: Keys.frameRateTrials)
        choicesRevision += 1
    }

    /// What the row asks of the host: display mode at the rate. 60 also as the cap, which a host that applies the cap
    /// by the interval alone (nxnative from 2026-11-09 on) takes. 120 without it, since nxnative takes a cap of 120 as
    /// 60 for a game whose profile has no `fps_max 120`: a 120 Hz present tick and display link instead, and the
    /// game's vsync event at 120 for a game that waits for it.
    static func frameRateTrialEnvironment(_ value: String) -> [String: String] {
        switch value {
        case "60": ["DM_FPS_TARGET": "60", "DM_PRESENT_INTERVAL": "display"]
        case "120":
            [
                "DM_PRESENT_INTERVAL": "display", "DM_PRESENT_HZ": "120", "DM_PRESENT_LINK": "2",
                "DM_VSYNC_HZ": "120",
            ]
        default: [:]
        }
    }
}
