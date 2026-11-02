import Foundation
import Network
import Observation

/// The Macs on the local network running NX Play with the iPhone & iPad App setting on. They advertise `_nxplay._tcp` over
/// Bonjour, with their `.local` host name and port in the TXT record (NXPlayKit's RemoteServer).
@MainActor @Observable
final class MacFinder {
    struct Found: Identifiable, Hashable {
        let name: String
        let host: String
        let port: Int
        var id: String { name }
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_nxplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        found =
            results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint,
                    case .bonjour(let txt) = result.metadata,
                    let host = txt["host"], !host.isEmpty
                else { return nil }
                return Found(name: name, host: host, port: Int(txt["port"] ?? "") ?? 47_474)
            }
            .sorted { $0.name < $1.name }
    }
}
