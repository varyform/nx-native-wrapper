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

/// A game installed on the device, as devicectl lists it.
struct DeviceGame: Decodable, Sendable {
    let bundleID: String
    let titleID: String
    let version: String
}

/// A Mac running NX Play, and the pairing code it showed in Settings › Devices › iPhone & iPad App.
struct MacClient: Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let host: String
    let port: Int
    let token: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // listing a device's apps asks devicectl, a few seconds; a build is followed by polling, never waited on
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    func info() async throws -> MacInfo { try await get("v1/info") }
    func games() async throws -> [RemoteGame] { try await get("v1/games") }
    func devices() async throws -> [RemoteDevice] { try await get("v1/devices") }

    func installed(on device: String) async throws -> [DeviceGame] {
        try await get("v1/devices/\(Self.part(device))/apps")
    }

    func install(_ game: RemoteGame, on device: String) async throws -> RemoteJob {
        try Self.decoder.decode(
            RemoteJob.self,
            from: try await data(
                "v1/games/\(Self.part(game.id))/install", query: ["device": device],
                method: "POST"))
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
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.percentEncodedPath = "/" + path
        if !query.isEmpty { components.queryItems = query.map(URLQueryItem.init) }
        guard let url = components.url else { throw Failure(message: "Bad address: \(host)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // the server's {"error": "…"} reads as it is
            let message = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
            throw Failure(message: message ?? "The Mac answered \(status)")
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
