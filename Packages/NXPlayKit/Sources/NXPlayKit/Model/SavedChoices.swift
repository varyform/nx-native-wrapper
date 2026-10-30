import Foundation

/// A game's own choices, in nxnative's store (docs/frontends.md, Saved choices): the preferences domain of the game's
/// Mac app, `org.nxnative.<title ID>`, one string per setting under `launcher.<variable>`. The Mac app's launcher and
/// its settings window read and write the same keys, so every view of a game's choices agrees. NX Play's global values
/// stay in NX Play: a play passes them in the environment, under the game's own.
struct SavedChoices {
    let defaults: UserDefaults

    static func domain(titleID: String) -> String { "org.nxnative.\(titleID.lowercased())" }
    static func key(_ env: String) -> String { "launcher.\(env)" }

    /// The saved choice, when this build still offers it; any other value is ignored, and left for the Mac app's
    /// window to replace, as its launcher does.
    func value(for setting: LauncherSetting) -> String? {
        defaults.string(forKey: Self.key(setting.env)).flatMap { setting.accepts($0) ? $0 : nil }
    }

    func set(_ value: String?, for env: String) {
        if let value {
            defaults.set(value, forKey: Self.key(env))
        } else {
            defaults.removeObject(forKey: Self.key(env))
        }
    }
}
