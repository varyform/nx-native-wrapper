import Foundation

/// What the Install & IPA window asks for a game: install it on a device or make an IPA file, with the game files in
/// the app or copied on their own, signed through Xcode's team, with a .p12 certificate, or not at all.
public struct PackRequest: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case device(Device)
        /// An IPA in the game folder, to sideload or keep.
        case ipaFile
    }

    public enum Signing: String, Hashable, Sendable, CaseIterable {
        /// Xcode builds and signs it with the developer team, and installs it: the way Install on Device always has.
        case xcodeTeam
        /// A .p12 certificate and its provisioning profile sign the IPA, as sideloading tools do (issue #31).
        case certificate
        /// For a sideloading tool, which signs it with its own account.
        case unsigned
    }

    public var target: Target
    /// The game's RomFS goes into the app; without it the app is small, and the game files go into the app's folder on
    /// the device once per game version (issue #30).
    public var withGameFiles = true
    public var signing: Signing
    /// Copies the game files again although this Mac copied them to the device before: deleting the app deletes them.
    public var copyGameFilesAgain = false

    public init(target: Target, withGameFiles: Bool = true, signing: Signing, copyGameFilesAgain: Bool = false) {
        self.target = target
        self.withGameFiles = withGameFiles
        self.signing = signing
        self.copyGameFilesAgain = copyGameFilesAgain
    }

    public var device: Device? {
        if case .device(let device) = target { device } else { nil }
    }

    /// Xcode's signing installs (an IPA from Xcode would need an export it doesn't do here), and an unsigned app can't
    /// be installed.
    public var isPossible: Bool {
        switch (target, signing) {
        case (.device, .unsigned), (.ipaFile, .xcodeTeam): false
        default: true
        }
    }

    /// Install on Device as it always was: Xcode's team, the game files inside (Job.Kind.install).
    var isPlainInstall: Bool { device != nil && signing == .xcodeTeam && withGameFiles }

    /// For the log's and the job's titles.
    public var title: String {
        let what = device.map { "Install on \($0.name)" } ?? "Build IPA"
        var details: [String] = []
        if signing == .certificate { details.append("certificate") }
        if !withGameFiles { details.append("game files apart") }
        return details.isEmpty ? what : "\(what) (\(details.joined(separator: ", ")))"
    }

    /// nxplay's options for it, before the game folder: the certificate's files when it's signed with one. Xcode's
    /// team and the bundle ID go after the folder (Library.command).
    func options(p12: String, profile: String) -> [String] {
        var options: [String] = []
        switch (target, signing) {
        case (.device(let device), .xcodeTeam): options = ["--device", device.id]
        case (.ipaFile, _), (.device, _): options = ["--ipa"]
        }
        if signing == .certificate {
            options += ["--sign-p12", p12, "--sign-profile", profile]
            if let device { options += ["--install-on", device.id] }
        }
        if !withGameFiles { options.append("--without-game-files") }
        if !withGameFiles, device != nil, copyGameFilesAgain { options.append("--push-game-files") }
        return options
    }
}
