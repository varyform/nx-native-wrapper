import Foundation

/// A request from the iPad app. NX Play's server reads only as much HTTP/1.1 as the app sends: the request line and
/// the headers. There's no body, since everything the API takes fits in the path and the query.
struct RemoteRequest: Equatable, Sendable {
    let method: String
    /// The path's components, percent-decoded: /v1/games/Metroid%20Dread → ["v1", "games", "Metroid Dread"].
    let path: [String]
    let query: [String: String]
    /// By lowercased name.
    let headers: [String: String]

    /// The longest header the server waits for before it gives up on a client.
    static let maxHeader = 16 * 1024

    /// The request in `data`, or nil while the headers' end hasn't arrived (or they don't parse).
    static func parse(_ data: Data) -> RemoteRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
            let url = URLComponents(string: "http://nxplay" + parts[1])
        else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return RemoteRequest(
            method: String(parts[0]), path: url.path.split(separator: "/").map(String.init),
            query: query, headers: headers)
    }

    /// The `*` parts of the path when the request is `method` on `pattern` ("v1/games/*/icon"), nil otherwise.
    func route(_ method: String, _ pattern: String) -> [String]? {
        let parts = pattern.split(separator: "/")
        guard method == self.method, parts.count == path.count else { return nil }
        var captured: [String] = []
        for (part, actual) in zip(parts, path) {
            if part == "*" {
                captured.append(actual)
            } else if part != actual {
                return nil
            }
        }
        return captured
    }

    /// The pairing code the app sends as `Authorization: Bearer <code>`.
    var bearer: String? {
        guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }
}

struct RemoteResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> RemoteResponse {
        let body =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return RemoteResponse(status: status, contentType: "application/json", body: body)
    }

    /// `{"error": "…"}`: the app shows the message as it is.
    static func error(_ status: Int, _ message: String) -> RemoteResponse {
        json(["error": message], status: status)
    }

    static func file(_ url: URL) -> RemoteResponse {
        guard let body = try? Data(contentsOf: url) else { return error(404, "No such file") }
        let type =
            switch url.pathExtension.lowercased() {
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "webp": "image/webp"
            default: "application/octet-stream"
            }
        return RemoteResponse(status: 200, contentType: type, body: body)
    }

    /// The response on the wire. Each connection carries one request, so the server closes it after the response.
    var data: Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let head =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
