import Foundation

/// A request to the control API (ControlServer): HTTP/1.1 with an optional JSON body. Stricter than the iOS app's
/// RemoteRequest: an origin-form target only, every header once at most where it matters, a body only by
/// Content-Length (no chunked transfer), within ControlHTTP's limits.
struct ControlRequest: Sendable {
    let method: String
    /// The path's components, percent-decoded: /v1/jobs/job-3 → ["v1", "jobs", "job-3"].
    let path: [String]
    let query: [String: String]
    /// By lowercased name.
    let headers: [String: String]
    let body: Data

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

    var pathText: String { "/" + path.joined(separator: "/") }
}

enum ControlHTTP {
    /// The request line and headers.
    static let maxHead = 16 * 1024
    /// A JSON body.
    static let maxBody = 1024 * 1024

    enum Parse: Equatable {
        /// Not all of it has arrived yet.
        case incomplete
        case request(ControlRequestBox)
        /// Refused before any routing: the status and error code to answer with.
        case refused(status: Int, code: String, message: String)
    }

    /// `ControlRequest` isn't Equatable (Data bodies compare fine, but the point is the case): a box for `Parse`.
    struct ControlRequestBox: Equatable {
        let request: ControlRequest
        static func == (a: Self, b: Self) -> Bool {
            a.request.method == b.request.method && a.request.path == b.request.path && a.request.body == b.request.body
        }
    }

    /// Headers that may appear once at most: a second Content-Length or Host is how request smuggling and host
    /// confusion start, a second Authorization how a check reads one value and another layer the other.
    static let singleHeaders: Set<String> = ["content-length", "host", "authorization", "content-type", "origin"]

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead
                ? .refused(status: 431, code: "headers_too_large", message: "The request head is over 16 KiB")
                : .incomplete
        }
        guard end.lowerBound <= maxHead else {
            return .refused(status: 431, code: "headers_too_large", message: "The request head is over 16 KiB")
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .refused(status: 400, code: "bad_request", message: "The request head isn't UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .refused(status: 400, code: "bad_request", message: "Not an HTTP/1.1 request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        // origin-form only: an absolute URL (a proxy request) or `*` is refused
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
            let url = URLComponents(string: "http://control" + target)
        else {
            return .refused(status: 400, code: "bad_request", message: "The request target must be a path")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                return .refused(status: 400, code: "bad_request", message: "A header line has no colon")
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                return .refused(status: 400, code: "bad_request", message: "A header name is malformed")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil {
                if singleHeaders.contains(name) {
                    return .refused(status: 400, code: "bad_request", message: "The \(name) header is repeated")
                }
                headers[name] = headers[name]! + ", " + value
            } else {
                headers[name] = value
            }
        }
        if headers["transfer-encoding"] != nil {
            return .refused(
                status: 400, code: "bad_request", message: "Transfer-Encoding isn't accepted: send Content-Length")
        }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
                return .refused(status: 400, code: "bad_request", message: "Content-Length isn't a number")
            }
            length = value
        }
        guard length <= maxBody else {
            return .refused(status: 413, code: "payload_too_large", message: "The body is over 1 MiB")
        }
        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        guard available >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = ControlRequest(
            method: method, path: url.path.split(separator: "/").map(String.init), query: query,
            headers: headers, body: Data(body))
        return .request(ControlRequestBox(request: request))
    }
}

/// A JSON answer. Never cached, never sniffed, never shared with a web page: no CORS header is ever sent.
struct ControlResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> ControlResponse {
        ControlResponse(status: status, body: ControlJSON.data(object))
    }

    static func error(_ error: ControlError) -> ControlResponse {
        json(["ok": false, "error": error.json], status: error.status)
    }

    /// 202 for an MCP notification: nothing to say.
    static let accepted = ControlResponse(status: 202, body: Data())

    var data: Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json; charset=utf-8\r\n" }
        head +=
            "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// An error answer: `{"ok": false, "error": {"code", "message", "details"?}}` with a matching status.
struct ControlError: Error, Sendable, Equatable {
    let code: String
    let status: Int
    let message: String
    var details: [String: String]? = nil

    var json: [String: Any] {
        var json: [String: Any] = ["code": code, "message": message]
        if let details { json["details"] = details }
        return json
    }

    static func invalidArgs(_ message: String) -> ControlError {
        ControlError(code: "invalid_args", status: 400, message: message)
    }

    static func notFound(_ message: String) -> ControlError {
        ControlError(code: "not_found", status: 404, message: message)
    }

    static func conflict(_ message: String) -> ControlError {
        ControlError(code: "conflict", status: 409, message: message)
    }

    static func failed(_ message: String, status: Int = 422) -> ControlError {
        ControlError(code: "command_failed", status: status, message: message)
    }

    /// A Sources refusal, with the status the backend chose for it (the iOS app's API answers with it too).
    static func from(_ failure: Repositories.Failure) -> ControlError {
        let code =
            switch failure.status {
            case 404: "not_found"
            case 409: "conflict"
            case 429: "too_many"
            case 507: "insufficient_storage"
            default: "command_failed"
            }
        return ControlError(code: code, status: failure.status, message: failure.message)
    }
}

enum ControlJSON {
    /// Values JSONSerialization takes: Optionals unwrapped to NSNull, Dates as ISO 8601, URLs as paths.
    static func clean(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: return dictionary.mapValues(clean)
        case let array as [Any]: return array.map(clean)
        case let date as Date: return date.ISO8601Format()
        case let url as URL: return url.path
        // a parsed JSON boolean is a CFBoolean, which the numeric casts below would also match (true as 1): it
        // stays a boolean
        case let number as NSNumber where ControlType.isBool(number): return number
        case let int64 as Int64: return NSNumber(value: int64)
        case let uint16 as UInt16: return NSNumber(value: uint16)
        case let int32 as Int32: return NSNumber(value: int32)
        // JSON has no NaN or infinity, and JSONSerialization raises (an exception, not an error) on them
        case let double as Double: return double.isFinite ? double : NSNull()
        case let number as NSNumber:
            return ControlType.isBool(number) || !CFNumberIsFloatType(number) || number.doubleValue.isFinite
                ? number : NSNull()
        case is NSNull, is String, is Bool, is Int: return value
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return NSNull() }
                return clean(child.value)
            }
            return "\(value)"
        }
    }

    static func parse(_ data: Data) throws(ControlError) -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ControlError(code: "invalid_json", status: 400, message: "The body isn't JSON")
        }
    }

    /// The JSON text of `object`, cleaned first; `{}` for anything that still isn't valid JSON (checked before
    /// serializing: JSONSerialization raises on an invalid object rather than throwing).
    static func data(_ object: Any) -> Data {
        let cleaned = clean(object)
        guard JSONSerialization.isValidJSONObject(cleaned),
            let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return Data("{}".utf8) }
        return data
    }

    static func text(_ object: Any) -> String {
        let cleaned = clean(object)
        guard JSONSerialization.isValidJSONObject([cleaned]),
            let data = try? JSONSerialization.data(
                withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
