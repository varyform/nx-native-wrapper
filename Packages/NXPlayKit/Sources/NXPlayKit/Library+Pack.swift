import Foundation
import Observation

/// The Install & IPA window's choices for a game. The last ones are kept, so the next game starts from them; the
/// certificate's password is kept in the keychain.
@MainActor @Observable
public final class Packing {
    enum Keys {
        static let target = "packTarget"
        static let withGameFiles = "packWithGameFiles"
        static let signing = "packSigning"
        static let p12 = "packP12"
        static let profile = "packProfile"
    }

    public let game: Game
    public var toDevice: Bool
    /// The device's UDID; the first one listed when it isn't.
    public var deviceID: String?
    public var withGameFiles: Bool
    public var signing: PackRequest.Signing
    public var copyGameFilesAgain = false
    public var p12Path: String {
        didSet {
            password = SigningCertificate.password(for: p12Path) ?? ""
            checkCertificate()
        }
    }
    public var password: String { didSet { checkCertificate() } }
    public var profilePath: String { didSet { profile = Self.readProfile(profilePath) } }
    public private(set) var profile: ProvisioningProfile?
    public private(set) var certificate: SigningCertificate.Check?
    @ObservationIgnored private let defaults: UserDefaults

    init(game: Game, toDevice: Bool, defaults: UserDefaults) {
        self.game = game
        self.defaults = defaults
        self.toDevice = toDevice
        let target = defaults.string(forKey: Keys.target)
        deviceID = target == "ipa" ? nil : target
        withGameFiles = defaults.object(forKey: Keys.withGameFiles) as? Bool ?? true
        signing = defaults.string(forKey: Keys.signing).flatMap(PackRequest.Signing.init(rawValue:)) ?? .xcodeTeam
        p12Path = defaults.string(forKey: Keys.p12) ?? ""
        profilePath = defaults.string(forKey: Keys.profile) ?? ""
        password = SigningCertificate.password(for: defaults.string(forKey: Keys.p12) ?? "") ?? ""
        profile = Self.readProfile(profilePath)
        checkCertificate()
    }

    /// What Start runs; nil while something is missing (why: `missing`).
    public func request(devices: [Device]) -> PackRequest? {
        guard missing(devices: devices) == nil else { return nil }
        let target: PackRequest.Target =
            if toDevice, let device = device(in: devices) { .device(device) } else { .ipaFile }
        return PackRequest(
            target: target, withGameFiles: withGameFiles, signing: effectiveSigning,
            copyGameFilesAgain: copyGameFilesAgain)
    }

    /// Xcode's team installs and a certificate signs either; an IPA file can be left unsigned.
    public var effectiveSigning: PackRequest.Signing {
        switch (toDevice, signing) {
        case (true, .unsigned): .xcodeTeam
        case (false, .xcodeTeam): .unsigned
        default: signing
        }
    }

    public func device(in devices: [Device]) -> Device? {
        devices.first { $0.id == deviceID } ?? devices.first
    }

    /// Why Start can't run yet, said under its button.
    public func missing(devices: [Device]) -> String? {
        if toDevice, device(in: devices) == nil { return "No device: connect one, or pair it in Xcode." }
        guard effectiveSigning == .certificate else { return nil }
        if p12Path.isEmpty { return "Choose the .p12 certificate." }
        switch certificate {
        case .wrongPassword?: return "The certificate's password is wrong."
        case .unreadable?, nil: return "The .p12 file can't be read."
        case .valid?: break
        }
        guard let profile else {
            return profilePath.isEmpty ? "Choose the provisioning profile." : "The provisioning profile can't be read."
        }
        if profile.isExpired { return "The provisioning profile has expired." }
        if toDevice, let device = device(in: devices), !profile.allows(device) {
            return "The provisioning profile doesn't list \(device.name)."
        }
        return nil
    }

    /// Kept for the next time, the password in the keychain.
    func save() {
        defaults.set(toDevice ? deviceID : "ipa", forKey: Keys.target)
        defaults.set(withGameFiles, forKey: Keys.withGameFiles)
        defaults.set(signing.rawValue, forKey: Keys.signing)
        defaults.set(p12Path, forKey: Keys.p12)
        defaults.set(profilePath, forKey: Keys.profile)
        if effectiveSigning == .certificate, !p12Path.isEmpty {
            SigningCertificate.setPassword(password, for: p12Path)
        }
    }

    private func checkCertificate() {
        certificate = p12Path.isEmpty ? nil : SigningCertificate.check(URL(filePath: p12Path), password: password)
    }

    private static func readProfile(_ path: String) -> ProvisioningProfile? {
        path.isEmpty ? nil : ProvisioningProfile.read(URL(filePath: path))
    }
}

extension Library {
    /// Install on Device… and Build IPA… open the Install & IPA window for the game.
    public func openPacking(_ game: Game, toDevice: Bool) {
        packing = Packing(game: game, toDevice: toDevice, defaults: defaults)
        if toDevice { refreshDevices() }
    }

    /// The window's Start: Install on Device as it always was goes as one (the iPhone app's requests are those too).
    public func pack(_ packing: Packing) {
        guard let request = packing.request(devices: devices) else { return }
        packing.save()
        if request.isPlainInstall, let device = request.device {
            run(.install(device), packing.game)
        } else {
            run(.pack(request), packing.game)
        }
        self.packing = nil
    }

    /// nxplay's arguments for an install or an IPA; nil, with `problem` set, when it can't run.
    func packArguments(
        _ request: PackRequest, game: Game, lang: [String], environment: inout [String: String]
    ) -> [String]? {
        let p12 = defaults.string(forKey: Packing.Keys.p12) ?? ""
        var arguments = request.options(p12: p12, profile: defaults.string(forKey: Packing.Keys.profile) ?? "")
        arguments += lang + [game.folder.path]
        if request.signing == .certificate {
            environment["NXPLAY_P12_PASSWORD"] = SigningCertificate.password(for: p12) ?? ""
        }
        guard request.signing == .xcodeTeam else { return arguments }
        guard let team, let titleID = game.titleID else {
            problem = "No Apple developer team in Xcode. Add your account in Xcode › Settings › Apple Accounts."
            return nil
        }
        // a Personal Team cannot provision the Increased Memory Limit capability: build without it
        if team.isFree { environment["DM_ENTITLEMENTS"] = "" }
        return arguments + ["--team-id", team.id, "--bundle-id", Self.bundleID(titleID: titleID, team: team)]
    }
}
