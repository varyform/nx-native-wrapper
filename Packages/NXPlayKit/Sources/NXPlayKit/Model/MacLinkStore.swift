import Foundation
import Network

/// A paired Mac: one this Mac builds on (a host), or one allowed to build here (a client).
public struct PairedMac: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    let key: Data
}

/// Pairing state on disk, in `<AppHome>/remote`. Keys are in owner-only files rather than the Keychain, because an
/// ad-hoc signed app's Keychain items would ask for access again after every update.
struct MacLinkStore: Sendable {
    let directory: URL

    static var standard: MacLinkStore {
        MacLinkStore(directory: AppHome.folder.appending(path: "remote", directoryHint: .isDirectory))
    }

    /// This installation's permanent identity, which survives the Mac being renamed.
    func instanceID() -> String {
        let file = directory.appending(path: "instance-id")
        if let stored = try? String(contentsOf: file, encoding: .utf8), !stored.isEmpty { return stored }
        let created = UUID().uuidString
        write(Data(created.utf8), to: file)
        return created
    }

    func hosts() -> [PairedMac] { load("hosts.json") }
    func saveHosts(_ hosts: [PairedMac]) { save(hosts, to: "hosts.json") }
    func clients() -> [PairedMac] { load("clients.json") }
    func saveClients(_ clients: [PairedMac]) { save(clients, to: "clients.json") }

    private func load(_ name: String) -> [PairedMac] {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return [] }
        return (try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []
    }

    private func save(_ value: [PairedMac], to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data, to: directory.appending(path: name))
    }

    private func write(_ data: Data, to file: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // created with its final permissions and moved into place, so the keys are never readable by others
        let temporary = directory.appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(temporary.path, file.path) != 0 { try? manager.removeItem(at: temporary) }
    }
}

/// Another NX Play allowing remote builds on the local network.
public struct DiscoveredMac: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    let endpoint: NWEndpoint
}

/// Finds other Macs with Bonjour. Only ones with Allow Remote Builds on advertise themselves.
final class MacBrowser: Sendable {
    private let browser: NWBrowser

    init(excluding ownID: String, onChange: @escaping @Sendable ([DiscoveredMac]) -> Void) {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacWire.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                guard case .service(let name, _, _, _) = result.endpoint,
                    case .bonjour(let txt) = result.metadata,
                    let id = txt[MacWire.instanceIDKey], id != ownID
                else { return nil }
                return DiscoveredMac(id: id, name: name, endpoint: result.endpoint)
            }
            onChange(macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    func start() { browser.start(queue: DispatchQueue(label: "com.varyform.nxplay.mac-browser")) }
    func stop() { browser.cancel() }
}
