import Foundation
import Security

/// A repository the player added in Sources: a name and the address of its catalog. Kept in NX Play's settings
/// without any secret; a source's access token is in the Keychain (`CredentialStore`).
public struct RepositorySource: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: URL
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, url: URL, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
    }

    public var origin: RepositoryOrigin? { RepositoryOrigin(url) }

    var plist: [String: Any] {
        ["id": id, "name": name, "url": url.absoluteString, "enabled": enabled]
    }

    init?(plist: [String: Any]) {
        guard let id = plist["id"] as? String, let name = plist["name"] as? String,
            let link = plist["url"] as? String, let url = URL(string: link)
        else { return nil }
        self.init(id: id, name: name, url: url, enabled: plist["enabled"] as? Bool ?? true)
    }
}

/// Where sources' access tokens are kept: the Keychain in the app, memory in tests. A token that isn't there is nil;
/// a store that can't be read or written throws, so a failure is never taken for "no token" or for a saved one.
public protocol CredentialStore: Sendable {
    func token(for sourceID: String) throws -> String?
    /// Saves `token`, or deletes the source's token when it's nil or empty. When it throws, the token saved before is
    /// still the one there.
    func setToken(_ token: String?, for sourceID: String) throws
}

/// Why the Keychain refused, with its status.
public struct KeychainFailure: Error, LocalizedError, Equatable {
    public let status: OSStatus
    let action: String

    public var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        return "The Keychain couldn't \(action) the access token: \(reason) (\(status))"
    }
}

/// The login Keychain, one generic password per source (service com.varyform.nxplay.repository, the source's id as
/// the account). Never written to NX Play's settings or to a log. A new token replaces the saved one in place
/// (SecItemUpdate), and is added only when there's none yet, so a failed write never loses the old one.
public struct KeychainCredentials: CredentialStore {
    static let service = "com.varyform.nxplay.repository"

    /// The Security calls, which tests replace with their own statuses: they never touch a real Keychain.
    struct API: Sendable {
        var copyMatching: @Sendable ([String: Any]) -> (OSStatus, Data?)
        var add: @Sendable ([String: Any]) -> OSStatus
        var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        var delete: @Sendable ([String: Any]) -> OSStatus

        static let system = API(
            copyMatching: { query in
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            delete: { SecItemDelete($0 as CFDictionary) })
    }

    let api: API

    public init() { api = .system }

    init(api: API) { self.api = api }

    private func query(_ sourceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: sourceID,
        ]
    }

    public func token(for sourceID: String) throws -> String? {
        var query = query(sourceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = api.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data, let token = String(data: data, encoding: .utf8) else {
                throw KeychainFailure(status: errSecDecode, action: "read")
            }
            return token
        case errSecItemNotFound: return nil
        default: throw KeychainFailure(status: status, action: "read")
        }
    }

    public func setToken(_ token: String?, for sourceID: String) throws {
        guard let token, !token.isEmpty else {
            let status = api.delete(query(sourceID))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainFailure(status: status, action: "delete")
            }
            return
        }
        let data = Data(token.utf8)
        let updated = api.update(query(sourceID), [kSecValueData as String: data])
        switch updated {
        case errSecSuccess: return
        case errSecItemNotFound: break
        default: throw KeychainFailure(status: updated, action: "save")
        }
        var item = query(sourceID)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "NX Play repository token"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = api.add(item)
        switch added {
        case errSecSuccess: return
        case errSecDuplicateItem:
            // saved by someone else in between: replace that one
            let again = api.update(query(sourceID), [kSecValueData as String: data])
            guard again == errSecSuccess else { throw KeychainFailure(status: again, action: "save") }
        default: throw KeychainFailure(status: added, action: "save")
        }
    }
}

/// Tests' tokens. `failure` makes every read and write throw it, as a Keychain that's locked or refuses access does.
final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()
    var failure: (any Error)? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    private var _failure: (any Error)?

    func token(for sourceID: String) throws -> String? {
        try lock.withLock {
            if let _failure { throw _failure }
            return tokens[sourceID]
        }
    }

    func setToken(_ token: String?, for sourceID: String) throws {
        try lock.withLock {
            if let _failure { throw _failure }
            tokens[sourceID] = token?.isEmpty == false ? token : nil
        }
    }
}

/// A source's token with the only origin it goes to.
struct SourceAuth: Sendable {
    let origin: RepositoryOrigin
    let token: String

    /// The header for `url`, nil when the URL is elsewhere: a package hosted on another server, or a redirect.
    func header(for url: URL) -> String? {
        RepositoryOrigin(url) == origin ? "Bearer \(token)" : nil
    }
}
