import Foundation

/// When a device install stops opening: its provisioning profile's expiry, 7 days after the build for a Personal Team
/// and a year for a paid one. iOS then refuses to open the game until it's installed again.
enum Provisioning {
    /// The profile Install on Device's last build was signed with, which the device got with it.
    static func expiration(of game: Game) -> Date? {
        guard
            let profile = game.xcodeBuildFolder?.appending(
                path: "Build/Products/Release-iphoneos/DmIOS.app/embedded.mobileprovision"),
            let data = try? Data(contentsOf: profile)
        else { return nil }
        return expiration(ofProfile: data)
    }

    /// The profile is a signed CMS message with its property list inside as plain text: read the list out.
    static func expiration(ofProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}
