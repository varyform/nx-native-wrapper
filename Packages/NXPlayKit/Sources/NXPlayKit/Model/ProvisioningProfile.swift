import Foundation
import Security

/// A provisioning profile (.mobileprovision) for signing with a certificate, as the Install & IPA window shows it:
/// whose it is, until when, for which app ID and devices. nxplay signs with the file itself; this only reads it.
public struct ProvisioningProfile: Equatable, Sendable {
    public let name: String
    public let teamID: String
    public let teamName: String
    /// The app ID after the team: `com.example.game`, or a wildcard such as `*` or `com.example.*`.
    public let appID: String
    public let expires: Date
    /// The UDIDs it may be installed on; empty with `allDevices` (an enterprise profile).
    public let devices: [String]
    public let allDevices: Bool

    /// The profile in a .mobileprovision file: a CMS-signed property list.
    public static func read(_ url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url), let plist = decode(data) else { return nil }
        return parse(plist: plist)
    }

    static func parse(plist: Data) -> ProvisioningProfile? {
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
            let entitlements = root["Entitlements"] as? [String: Any],
            let identifier = entitlements["application-identifier"] as? String,
            let teamID = (root["TeamIdentifier"] as? [String])?.first,
            let expires = root["ExpirationDate"] as? Date
        else { return nil }
        return ProvisioningProfile(
            name: root["Name"] as? String ?? "",
            teamID: teamID,
            teamName: root["TeamName"] as? String ?? teamID,
            appID: identifier.hasPrefix(teamID + ".") ? String(identifier.dropFirst(teamID.count + 1)) : identifier,
            expires: expires,
            devices: root["ProvisionedDevices"] as? [String] ?? [],
            allDevices: root["ProvisionsAllDevices"] as? Bool ?? false)
    }

    public var isExpired: Bool { expires < .now }

    /// Whether the device may run what it signs: one of its devices, or any with an enterprise profile. devicectl's
    /// UDIDs and the profile's differ in letter case at times.
    public func allows(_ device: Device) -> Bool {
        allDevices || devices.contains { $0.caseInsensitiveCompare(device.id) == .orderedSame }
    }

    private static func decode(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let added = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        guard added == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }
}

/// The .p12 certificate the window signs with: whose it is, once its password opens it. The password is kept in the
/// login keychain, by the file's path.
public enum SigningCertificate {
    public enum Check: Equatable, Sendable {
        case valid(name: String)
        case wrongPassword
        case unreadable
    }

    public static func check(_ url: URL, password: String) -> Check {
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        var items: CFArray?
        let status = SecPKCS12Import(
            data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { return .wrongPassword }
        guard status == errSecSuccess,
            let first = (items as? [[String: Any]])?.first,
            let item = first[kSecImportItemIdentity as String], CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID()
        else { return .unreadable }
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(item as! SecIdentity, &certificate)
        let name = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate"
        return .valid(name: name)
    }

    static let service = "com.varyform.nxplay.p12"

    public static func password(for path: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: path, kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, for path: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: path,
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "NX Play: certificate password"
        SecItemAdd(add as CFDictionary, nil)
    }
}
