import Foundation

/// What NX Play's server on the Mac answers (NXPlayKit's Library+Remote.swift has the other side).
struct MacInfo: Decodable, Sendable {
    struct Team: Decodable, Sendable {
        let name: String
        let free: Bool
    }

    let name: String
    let version: String
    let team: Team?
    /// The Mac's pairing ID (PairingLink.macID); nil from a Mac before QR pairing.
    let id: String?
}

struct RemoteGame: Decodable, Identifiable, Hashable, Sendable {
    /// The game's folder name on the Mac.
    let id: String
    let name: String
    let titleID: String?
    let version: String?
    /// notExtracted, extracted or ready (NXPlayKit's Game.State).
    let state: String
    let kept: Bool
    let canInstall: Bool
    let hasIcon: Bool
    let job: RemoteJob?
    /// When the copy the Mac installed stops opening: its provisioning profile's expiry.
    let expires: Date?
}

struct RemoteJob: Decodable, Hashable, Sendable {
    /// install, play, rebuild, …
    let kind: String
    /// The UDID an install goes to.
    let device: String?
    /// queued, running, succeeded, failed or cancelled.
    let status: String
    let fraction: Double
    /// "6/6 Xcode build · ANIMAL WELL (010020D01AD24000)"
    let text: String
    /// A failure's last log lines.
    let lastLines: [String]?

    var isActive: Bool { status == "queued" || status == "running" }
}

struct RemoteDevice: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let model: String
    let os: String
}

/// What a device has: its games as devicectl lists them, and the ones deleted from it (title IDs).
struct DeviceGames: Decodable, Sendable {
    struct App: Decodable, Sendable {
        let bundleID: String
        let titleID: String
        let version: String
    }

    let apps: [App]
    let removed: [String]
}

/// A source on the Mac (Tools › Sources…): the player's own repository of game files, with its catalog's state.
struct RemoteSource: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// https://nas.local:8443: where the catalog is, without its path.
    let origin: String
    let enabled: Bool
    /// notLoaded, loading, loaded or failed.
    let state: String
    let error: String?
    let entries: Int
    /// Entries the Mac left out of the catalog (a bad line, an archive).
    let issues: Int
    let refreshed: Date?
}

/// A game in a source's catalog, with what's in the Mac's games folder already.
struct RemoteEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let titleID: String
    let version: String
    let publisher: String
    let description: String
    /// The game's folder in the Mac's games folder.
    let folder: String
    /// The library's game in that folder (a RemoteGame's id), once there is one: Install takes it from there.
    let libraryGame: String?
    let issues: [String]
    let packages: [RemotePackage]
}

struct RemotePackage: Decodable, Identifiable, Hashable, Sendable {
    /// The file's SHA-256, or sha1:<hex>: what the Mac downloads it by.
    let id: String
    /// base, update or dlc.
    let kind: String
    let filename: String
    let bytes: Int64
    /// The algorithm of the checksum the Mac checks it against: sha256 or sha1. A Mac from before SHA-1 sends none;
    /// it checks only SHA-256.
    let checksum: String?
    let titleID: String?
    let version: Int?
    /// In the game's folder on the Mac already.
    let present: Bool
    /// The download bringing it, while one does.
    let download: String?

    /// As people write it: SHA-256, SHA-1.
    var checksumLabel: String {
        switch checksum ?? "sha256" {
        case "sha256": "SHA-256"
        case "sha1": "SHA-1"
        case let other: other.uppercased()
        }
    }
}

/// A download on the Mac, into its games folder.
struct RemoteDownload: Decodable, Identifiable, Hashable, Sendable {
    struct File: Decodable, Hashable, Sendable {
        let kind: String
        let filename: String
        let bytes: Int64
    }

    let id: String
    let source: String
    let sourceName: String
    let entry: String
    let entryName: String
    let titleID: String
    let folder: String
    /// queued, running, verifying, succeeded, failed or cancelled.
    let state: String
    let message: String?
    let bytesDone: Int64
    let totalBytes: Int64
    let fraction: Double
    let fileIndex: Int
    let files: [File]
    /// The library's game it made, once it succeeded.
    let libraryGame: String?

    var isActive: Bool { state == "queued" || state == "running" || state == "verifying" }
}

/// A Mac running NX Play, and the pairing code it showed in Settings › Devices › iPhone & iPad App.
struct MacClient: Sendable {
    struct Failure: LocalizedError {
        let message: String
        /// The HTTP status the Mac answered with; 0 when it didn't answer.
        var status = 0
        var errorDescription: String? { message }
    }

    /// What answers at an address, asked without the code (`GET /v1/hello`).
    enum Hello: Equatable, Sendable {
        case nxplay(PairingHello)
        /// NX Play from before QR pairing: it wants the code for everything, /v1/hello too.
        case olderNXPlay
        /// Something else answered.
        case notNXPlay
    }

    let endpoint: Endpoint
    let token: String

    init(endpoint: Endpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    /// How every request to the Mac goes: straight to the address asked, without a proxy, and without following
    /// redirects. A proxy set for the network (Wi-Fi › Configure Proxy, or a PAC file) would see the code, so it isn't
    /// used. A redirect could make another server's `/v1/hello` vouch for this address, or take a request elsewhere,
    /// so it reads as the answer it is: a 3xx, which is neither NX Play nor a success.
    static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        // listing a device's apps asks devicectl, a few seconds; a build is followed by polling, never waited on
        configuration.timeoutIntervalForRequest = 30
        // an empty dictionary rather than nil (the system's proxies): no proxy at all
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return configuration
    }()

    private static let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)

    /// Refuses every redirect (see `configuration`).
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    /// One request, answered by the address it went to: an answer from anywhere else is refused.
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (body, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, let asked = request.url, Self.sameOrigin(http.url, asked) else {
            throw Failure(message: "\(endpoint.display) answered from somewhere else.")
        }
        return (body, http.statusCode)
    }

    static func sameOrigin(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }

    /// Whether NX Play answers here, and which Mac: no code is sent, so a wrong or stale address never gets it. The
    /// answer is a claim, not proof: anything on the network can send the same words, so it only keeps the code from
    /// going to the wrong Mac or to something else by mistake (PairingTrust says where the code may go).
    func hello() async throws -> Hello {
        guard let url = endpoint.url(path: "v1/hello") else { throw Failure(message: "Bad address: \(endpoint.display)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (body, status) = try await send(request)
        if status == 200, let hello = try? JSONDecoder().decode(PairingHello.self, from: body),
            hello.app == NXPlayPairing.helloApp
        {
            return .nxplay(hello)
        }
        // an older NX Play: {"error": "Wrong pairing code: …"} for a request without one
        if status == 401, let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"],
            message.contains("pairing code")
        {
            return .olderNXPlay
        }
        return .notNXPlay
    }

    func info() async throws -> MacInfo { try await get("v1/info") }
    func games() async throws -> [RemoteGame] { try await get("v1/games") }
    func devices() async throws -> [RemoteDevice] { try await get("v1/devices") }

    func installed(on device: String) async throws -> DeviceGames {
        try await get("v1/devices/\(Self.part(device))/apps")
    }

    func install(_ game: RemoteGame, on device: String) async throws -> RemoteJob {
        try Self.decoder.decode(
            RemoteJob.self,
            from: try await data(
                "v1/games/\(Self.part(game.id))/install", query: ["device": device],
                method: "POST"))
    }

    // MARK: Sources (NXPlayKit's Library+Repositories.swift)

    func sources() async throws -> [RemoteSource] { try await get("v1/sources") }

    func refreshSources() async throws -> [RemoteSource] {
        try Self.decoder.decode([RemoteSource].self, from: try await data("v1/sources/refresh", method: "POST"))
    }

    func entries(of source: String, matching words: String) async throws -> [RemoteEntry] {
        try Self.decoder.decode(
            [RemoteEntry].self,
            from: try await data("v1/sources/\(Self.part(source))/entries", query: words.isEmpty ? [:] : ["q": words]))
    }

    func downloads() async throws -> [RemoteDownload] { try await get("v1/downloads") }

    /// Asks the Mac to download the packages (by checksum) into its games folder.
    func download(_ entry: RemoteEntry, from source: String, packages: [String]) async throws -> RemoteDownload {
        try Self.decoder.decode(
            RemoteDownload.self,
            from: try await data(
                "v1/downloads",
                query: ["source": source, "entry": entry.id, "packages": packages.joined(separator: ",")],
                method: "POST"))
    }

    func cancelDownload(_ id: String) async throws {
        _ = try await data("v1/downloads/\(Self.part(id))/cancel", method: "POST")
    }

    func retryDownload(_ id: String) async throws {
        _ = try await data("v1/downloads/\(Self.part(id))/retry", method: "POST")
    }

    func icon(_ game: RemoteGame) async throws -> Data {
        try await data("v1/games/\(Self.part(game.id))/icon")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try Self.decoder.decode(T.self, from: try await data(path))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func data(_ path: String, query: [String: String] = [:], method: String = "GET")
        async throws -> Data
    {
        guard let url = endpoint.url(path: path, query: query.map(URLQueryItem.init)) else {
            throw Failure(message: "Bad address: \(endpoint.display)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, status) = try await send(request)
        guard (200..<300).contains(status) else {
            // the server's {"error": "…"} reads as it is
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            throw Failure(message: message ?? "The Mac answered \(status)", status: status)
        }
        return body
    }

    /// One path component, percent-encoded: game folders have spaces and brackets ("Animal Well [NSP]").
    private static func part(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

extension MacClient {
    /// A failure in words that say what to do: the Mac's own message, else what the network said, with what to
    /// check for this kind of address. `localNetworkDenied`: Bonjour said NX Play may not use the local network.
    static func describe(_ error: any Error, at endpoint: Endpoint, localNetworkDenied: Bool, device: String) -> String {
        if let failure = error as? Failure { return failure.message }
        let permission =
            "NX Play isn't allowed on the local network: turn it on in Settings › Privacy & Security › Local Network › NX Play, then try again."
        guard let error = error as? URLError else { return error.localizedDescription }
        let address = endpoint.display
        switch (error.code, endpoint.kind) {
        case (.appTransportSecurityRequiresSecureConnection, _):
            return "iOS allows NX Play's plain HTTP only to IP addresses, local names (.local) and Tailscale names (.ts.net): type the Mac's address instead of \(endpoint.host)."
        case (.cannotFindHost, .tailscale), (.dnsLookupFailed, .tailscale):
            return "Can't find \(endpoint.host): turn on Tailscale on this \(device), with MagicDNS, or type the Mac's 100.x address."
        case (.cannotFindHost, _), (.dnsLookupFailed, _):
            return "Can't find \(endpoint.host) from this network. Check this \(device) is on the Mac's network, or type the Mac's IP address (NX Play › Settings › Devices lists them)."
        case (.cannotConnectToHost, _):
            return "\(address) turned the connection down: check NX Play is open on the Mac with the iPhone & iPad App setting on, and that the port is the one Settings › Devices shows."
        case (.timedOut, .tailscale):
            return "No answer from \(address): check Tailscale is connected on this \(device) and on the Mac, and the Mac is awake."
        case (.timedOut, .lan), (.notConnectedToInternet, .lan), (.networkConnectionLost, .lan):
            if localNetworkDenied { return permission }
            return "No answer from \(address): check this \(device) is on the same Wi-Fi as the Mac, the Mac is awake, and NX Play may use the local network (Settings › Privacy & Security › Local Network)."
        case (.timedOut, _):
            return "No answer from \(address): check the Mac is awake and reachable from this network."
        case (.notConnectedToInternet, _):
            return "This \(device) isn't connected to a network."
        default:
            return "\(address): \(error.localizedDescription)"
        }
    }
}

/// Where the saved pairing code may go without asking the player again.
///
/// NX Play talks plain HTTP and the Mac has no key the app could check, so nothing an address answers proves it is
/// the paired Mac: its ID is public (Bonjour's TXT record, `/v1/hello`), and anything on the network can repeat it.
/// So the saved code goes only to addresses the player confirmed when pairing: the pairing link's (shown before
/// pairing), the one typed in, or those of the Mac picked from the list. Bonjour finding the Mac's ID elsewhere is
/// only a hint: the library says so and offers to pair again (QR code, or the address and code typed in), which sends
/// the code the player gives there, never the saved one.
///
/// What this assumes: the networks of the confirmed addresses. On Wi-Fi the code travels in clear, so whoever can
/// read that network's traffic, or take over a confirmed address there, can learn it, as with a code typed by hand.
/// Over Tailscale, WireGuard encrypts the traffic and the 100.x addresses belong to the tailnet's own devices, but
/// only while Tailscale is connected on this device: without it, a 100.x address is someone else's network.
enum PairingTrust {
    /// The addresses to try the saved code at when the preferred one stops answering: the other confirmed ones.
    static func reconnectCandidates(_ paired: PairedMac) -> [Endpoint] {
        Array(paired.endpoints.dropFirst())
    }

    /// Addresses where Bonjour sees the paired Mac's ID but that the player never confirmed: the code doesn't go
    /// there by itself.
    static func unconfirmedAddresses(of paired: PairedMac?, found: [(macID: String?, endpoints: [Endpoint])]) -> [Endpoint] {
        guard let paired, let id = paired.macID else { return [] }
        var addresses: [Endpoint] = []
        for mac in found where mac.macID == id {
            for endpoint in mac.endpoints where !paired.endpoints.contains(endpoint) && !addresses.contains(endpoint) {
                addresses.append(endpoint)
            }
        }
        return addresses
    }
}

/// Pairing with a Mac at one of several addresses, and finding it again at another later (Launcher). The code goes
/// only to an address that answered `/v1/hello` as NX Play on the expected Mac, so a stale address, another Mac or
/// something else answering by mistake never receives it (it doesn't stop an impostor: see PairingTrust). Cancelled,
/// it stops before sending the code anywhere else. On the main actor, with the app's state; the requests themselves
/// run elsewhere.
@MainActor enum PairingAttempt {
    struct Success: Sendable {
        let endpoint: Endpoint
        /// The Mac's ID: from /v1/hello, else from /v1/info; nil from a Mac before QR pairing.
        let macID: String?
        let info: MacInfo
        let devices: [RemoteDevice]
    }

    /// Whether NX Play on the right Mac answers at `endpoint`, asked without the code. `expectedID` nil takes any NX
    /// Play, an older one included (an address typed in, or a Mac before QR pairing).
    static func check(_ endpoint: Endpoint, expectedID: String?) async throws -> Result<String?, PairingFailure> {
        switch try await MacClient(endpoint: endpoint, token: "").hello() {
        case .nxplay(let hello):
            if let expectedID, hello.id != expectedID { return .failure(.otherMac(endpoint)) }
            return .success(hello.id)
        case .olderNXPlay:
            // a link names a Mac that has /v1/hello: an older NX Play there is another Mac
            return expectedID == nil ? .success(nil) : .failure(.otherMac(endpoint))
        case .notNXPlay:
            return .failure(.notNXPlay(endpoint))
        }
    }

    /// Tries the addresses in order; the first where the right NX Play answers and takes the code wins. A wrong code
    /// stops it (it's wrong at every address). The failures come back in words, `describe` putting network errors.
    static func run(
        endpoints: [Endpoint], token: String, expectedID: String?,
        describe: (any Error, Endpoint) -> String
    ) async -> Result<Success, PairingFailures> {
        var failures: [String] = []
        addresses: for endpoint in endpoints {
            guard !Task.isCancelled else { break }
            do {
                let macID: String?
                switch try await check(endpoint, expectedID: expectedID) {
                case .success(let id): macID = id
                case .failure(let failure):
                    failures.append(failure.message)
                    continue
                }
                // cancelled while asking: the code doesn't go out
                try Task.checkCancellation()
                let client = MacClient(endpoint: endpoint, token: token)
                let info = try await client.info()
                try Task.checkCancellation()
                let devices = try await client.devices()
                return .success(Success(endpoint: endpoint, macID: macID ?? info.id, info: info, devices: devices))
            } catch _ where Task.isCancelled {
                break addresses
            } catch let failure as MacClient.Failure where failure.status == 401 {
                failures.append(failure.message)
                break addresses
            } catch {
                failures.append(describe(error, endpoint))
            }
        }
        return .failure(PairingFailures(messages: failures))
    }
}

enum PairingFailure: Error, Equatable {
    case otherMac(Endpoint)
    case notNXPlay(Endpoint)

    var message: String {
        switch self {
        case .otherMac(let endpoint): "\(endpoint.display) is NX Play on another Mac."
        case .notNXPlay(let endpoint): "\(endpoint.display) answered, but it isn't NX Play."
        }
    }
}

struct PairingFailures: Error, Equatable {
    let messages: [String]

    /// One failure as it is; several as a short list.
    var text: String {
        messages.count == 1 ? messages[0] : messages.prefix(3).map { "• \($0)" }.joined(separator: "\n")
    }
}
