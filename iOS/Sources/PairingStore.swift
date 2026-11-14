import Foundation
import Security

/// The paired Mac, kept between launches (PairingStore): its name and ID, the addresses it was reached at (the one
/// that last worked first), its pairing code, and which of its devices this one is. An iPhone or iPad can't learn its
/// own UDID (iOS hides it), so the player picks it once from the Mac's list.
struct PairedMac: Equatable {
    var name: String
    /// The Mac's pairing ID (/v1/hello); nil for a Mac from before QR pairing.
    var macID: String?
    /// Never empty.
    var endpoints: [Endpoint]
    var token: String
    var device: String?

    var endpoint: Endpoint { endpoints[0] }
    var client: MacClient { MacClient(endpoint: endpoint, token: token) }
}

/// The paired Mac as kept between launches: where it is in UserDefaults, its pairing code in the Keychain (this
/// device only, after the first unlock). A Mac paired before the Keychain moves its code there at the next launch.
/// When the Keychain refuses, the code stays in UserDefaults as before, so the pairing isn't lost.
enum PairingStore {
    static let macKey = "pairedMac"

    /// What UserDefaults holds: the code only when the Keychain refused it (and in a pairing from before).
    private struct Stored: Codable {
        var name: String
        var macID: String?
        var endpoints: [Endpoint]?
        var device: String?
        var token: String?
        // a pairing from before QR pairing
        var host: String?
        var port: Int?
    }

    static func load(_ defaults: UserDefaults = .standard, vault: any TokenVault = KeychainVault()) -> PairedMac? {
        guard let data = defaults.data(forKey: macKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        var endpoints = stored.endpoints ?? []
        if endpoints.isEmpty, let host = stored.host {
            let port = UInt16(exactly: stored.port ?? 0).flatMap { $0 > 0 ? $0 : nil } ?? NXPlayPairing.defaultPort
            // what the old app was given, as it was given, if it doesn't read as an address now
            endpoints = [(try? Endpoint.parse(host, defaultPort: port)) ?? Endpoint(validHost: host, port: port)]
        }
        // a code in UserDefaults is the newest: it's there only when the Keychain refused the last one
        guard !endpoints.isEmpty, let token = stored.token ?? vault.read() else { return nil }
        let mac = PairedMac(name: stored.name, macID: stored.macID, endpoints: endpoints, token: token, device: stored.device)
        // a code still in UserDefaults moves to the Keychain
        if stored.token != nil || stored.host != nil { save(mac, defaults, vault: vault) }
        return mac
    }

    static func save(_ mac: PairedMac?, _ defaults: UserDefaults = .standard, vault: any TokenVault = KeychainVault()) {
        guard let mac else {
            defaults.removeObject(forKey: macKey)
            vault.delete()
            return
        }
        let inKeychain = vault.write(mac.token)
        let stored = Stored(
            name: mac.name, macID: mac.macID, endpoints: mac.endpoints, device: mac.device,
            token: inKeychain ? nil : mac.token)
        defaults.set(try? JSONEncoder().encode(stored), forKey: macKey)
    }
}

/// Where the pairing code is kept apart from UserDefaults.
protocol TokenVault {
    func read() -> String?
    /// False when it couldn't be kept.
    func write(_ token: String) -> Bool
    func delete()
}

/// The Keychain: a generic password for this app, on this device only, readable after the first unlock.
struct KeychainVault: TokenVault {
    var service = "org.nxplay.ios.pairing"
    var account = "pairedMac"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        switch SecItemUpdate(query as CFDictionary, update as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var add = query
            add.merge(update) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
