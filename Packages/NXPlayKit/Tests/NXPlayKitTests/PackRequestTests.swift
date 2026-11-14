import Foundation
import Testing

@testable import NXPlayKit

/// The Install & IPA window (issues #30 and #31): what each choice asks nxplay for, the provisioning profile it reads,
/// and what keeps Start off.
@MainActor @Suite final class PackRequestTests {
    let phone = Device(id: "00008160-000925EE04C1400A", name: "Phone", model: "iPhone 18 Pro", osVersion: "27.3")
    private var suites: [String] = []

    deinit { suites.forEach(removeTestDefaults) }

    @Test func eachChoiceIsItsNxplayOptions() {
        let p12 = "/certs/me.p12", profile = "/certs/me.mobileprovision"
        let xcode = PackRequest(target: .device(phone), signing: .xcodeTeam)
        #expect(xcode.isPlainInstall && xcode.options(p12: p12, profile: profile) == ["--device", phone.id])

        let apart = PackRequest(
            target: .device(phone), withGameFiles: false, signing: .xcodeTeam, copyGameFilesAgain: true)
        #expect(!apart.isPlainInstall)
        #expect(
            apart.options(p12: p12, profile: profile) == [
                "--device", phone.id, "--without-game-files", "--push-game-files",
            ])

        let file = PackRequest(target: .ipaFile, withGameFiles: false, signing: .unsigned, copyGameFilesAgain: true)
        #expect(file.options(p12: p12, profile: profile) == ["--ipa", "--without-game-files"])

        let signed = PackRequest(target: .device(phone), signing: .certificate)
        #expect(
            signed.options(p12: p12, profile: profile) == [
                "--ipa", "--sign-p12", p12, "--sign-profile", profile, "--install-on", phone.id,
            ])
        #expect(signed.title == "Install on Phone (certificate)")

        #expect(!PackRequest(target: .device(phone), signing: .unsigned).isPossible)
        #expect(!PackRequest(target: .ipaFile, signing: .xcodeTeam).isPossible)
    }

    @Test func readsAProvisioningProfile() throws {
        let profile = try #require(ProvisioningProfile.parse(plist: Self.profile(appID: "ABCDE12345.com.example.*")))
        #expect(profile.name == "Games" && profile.teamName == "Example Ltd" && profile.appID == "com.example.*")
        #expect(profile.allows(phone))  // listed in lower case
        #expect(!profile.allows(Device(id: "OTHER", name: "Other", model: "iPad", osVersion: "27")))
        #expect(!profile.isExpired)

        let enterprise = try #require(
            ProvisioningProfile.parse(plist: Self.profile(appID: "ABCDE12345.*", devices: nil, expired: true)))
        #expect(enterprise.allDevices && enterprise.isExpired && enterprise.appID == "*")
        #expect(ProvisioningProfile.parse(plist: Data("not a plist".utf8)) == nil)
    }

    @Test func startWaitsForWhatTheChoiceNeeds() throws {
        let suite = testDefaultsName()
        suites.append(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let game = NXNativeRepoTests.game(in: URL(filePath: "/g/Zelda"), titleID: "01007EF00011E000")
        let packing = Packing(game: game, toDevice: true, defaults: defaults)

        #expect(packing.missing(devices: []) != nil)  // no device
        #expect(packing.request(devices: [phone])?.target == PackRequest.Target.device(phone))
        #expect(packing.effectiveSigning == .xcodeTeam)

        packing.toDevice = false
        #expect(packing.effectiveSigning == .unsigned)  // an IPA file can't come from Xcode here
        packing.signing = .certificate
        #expect(packing.missing(devices: []) == "Choose the .p12 certificate.")
        packing.p12Path = "/nowhere/me.p12"
        #expect(packing.missing(devices: []) == "The .p12 file can't be read.")

        // the last choices are the next game's
        packing.withGameFiles = false
        packing.save()
        let next = Packing(game: game, toDevice: false, defaults: defaults)
        #expect(!next.withGameFiles && next.signing == .certificate && next.p12Path == "/nowhere/me.p12")
    }

    static func profile(appID: String, devices: [String]? = ["00008160-000925ee04c1400a"], expired: Bool = false)
        -> Data
    {
        var root: [String: Any] = [
            "Name": "Games", "TeamName": "Example Ltd", "TeamIdentifier": ["ABCDE12345"],
            "ExpirationDate": Date.now.addingTimeInterval(expired ? -86_400 : 86_400 * 300),
            "Entitlements": ["application-identifier": appID],
        ]
        if let devices { root["ProvisionedDevices"] = devices } else { root["ProvisionsAllDevices"] = true }
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}
