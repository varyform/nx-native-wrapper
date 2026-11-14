import Foundation

/// Where the Mac's server is: a host (an IPv4 or IPv6 address, or a name such as mac.local or
/// mac.tailnet.ts.net) and a port. IPv6 addresses are kept without brackets; `display` and URLs add them.
struct Endpoint: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// The local network: a .local or single-label name, a private or link-local address.
        case lan
        /// Tailscale: 100.64.0.0/10, fd7a:115c:a1e0::/48, or a MagicDNS name (*.ts.net).
        case tailscale
        case other
    }

    let host: String
    let port: UInt16

    /// Checked: use `parse` for text from outside.
    init(validHost host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    var isIPv6: Bool { host.contains(":") }
    var kind: Kind { Self.kind(of: host) }
    /// The host as a URL has it: an IPv6 address in brackets.
    var urlHost: String { isIPv6 ? "[\(host)]" : host }
    /// As people type it: host:port, [IPv6]:port.
    var display: String { "\(urlHost):\(port)" }

    /// http://host:port/<path>, with the query; nil only if the host doesn't make a URL.
    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = urlHost
        components.port = Int(port)
        components.percentEncodedPath = "/" + path
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// An address as typed or as a link has it: host, host:port, [IPv6]:port, a bare IPv6 address, optionally after
    /// http://. Without a port, `defaultPort`; a link's addresses always have one (`defaultPort` nil).
    static func parse(_ text: String, defaultPort: UInt16?) throws(PairingError) -> Endpoint {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { throw .badAddress("Type the Mac's address.") }
        guard rest.utf8.count <= 300 else { throw .badAddress("That address is too long.") }
        if let scheme = rest.range(of: "://") {
            guard rest[..<scheme.lowerBound].lowercased() == "http" else {
                throw .badAddress("Type only the Mac's address and port, such as 192.168.1.20:47474.")
            }
            rest = String(rest[scheme.upperBound...])
            if rest.hasSuffix("/") { rest.removeLast() }
        }
        let host: String
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw .badAddress("An IPv6 address in brackets needs its closing bracket.") }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.first == ":" else { throw .badAddress("After the brackets, only :port can follow.") }
                portText = after.dropFirst()
            }
            guard host.contains(":") else { throw .badAddress("Brackets are only for IPv6 addresses.") }
        } else {
            let colons = rest.filter { $0 == ":" }.count
            if colons >= 2 {
                host = rest  // a bare IPv6 address: no port, unless in brackets
            } else if colons == 1, let colon = rest.firstIndex(of: ":") {
                host = String(rest[..<colon])
                portText = rest[rest.index(after: colon)...]
            } else {
                host = rest
            }
        }
        let port: UInt16
        if let portText {
            guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
                let value = UInt16(portText), value > 0
            else { throw .badPort }
            port = value
        } else if let defaultPort {
            port = defaultPort
        } else {
            throw .badPort
        }
        return Endpoint(validHost: try validatedHost(host), port: port)
    }

    /// The host in its usual form (lowercase, IPv6 compressed), or why it can't be one.
    static func validatedHost(_ host: String) throws(PairingError) -> String {
        if host.contains(":") {
            guard !host.contains("%") else {
                throw .badAddress("Addresses with an interface (%…) aren't supported: use the Mac's other address.")
            }
            guard let bytes = ipv6Bytes(host) else { throw .badAddress("\(host) isn't an IPv6 address.") }
            // an IPv4 address written as IPv6 (::ffff:a.b.c.d) is checked, and kept, as the IPv4 address it is
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return try validatedIPv4(Array(bytes.suffix(4)), as: host)
            }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 {
                throw .badAddress("Link-local addresses (fe80::) need an interface: use the Mac's other address.")
            }
            if bytes[0] == 0xff { throw .badAddress("\(host) is a multicast address, not the Mac's.") }
            if bytes.allSatisfy({ $0 == 0 }) { throw .badAddress("\(host) isn't a Mac's address.") }
            return ipv6String(bytes)
        }
        if !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            guard let bytes = ipv4Bytes(host) else { throw .badAddress("\(host) isn't an IPv4 address.") }
            return try validatedIPv4(bytes, as: host)
        }
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !name.isEmpty, name.utf8.count <= 253,
            labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.allSatisfy(allowed.contains)
                    && label.first != "-" && label.last != "-"
            })
        else {
            throw .badAddress("\(host) isn't a host name or address. Use a name such as mac.local, or an address.")
        }
        return name
    }

    /// An IPv4 address in dotted form, unless it can't be a Mac's (unspecified, broadcast, multicast or reserved).
    private static func validatedIPv4(_ bytes: [UInt8], as host: String) throws(PairingError) -> String {
        if bytes == [0, 0, 0, 0] || bytes == [255, 255, 255, 255] || bytes[0] >= 224 {
            throw .badAddress("\(host) isn't a Mac's address.")
        }
        return bytes.map(String.init).joined(separator: ".")
    }

    static func kind(of host: String) -> Kind {
        if let bytes = ipv4Bytes(host) {
            switch (bytes[0], bytes[1]) {
            case (100, 64...127): return .tailscale
            case (10, _), (172, 16...31), (192, 168), (169, 254): return .lan
            default: return .other
            }
        }
        if let bytes = ipv6Bytes(host) {
            if bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) { return .tailscale }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return .lan }
            return .other
        }
        if host.hasSuffix(".ts.net") { return .tailscale }
        if host.hasSuffix(".local") || !host.contains(".") { return host == "localhost" ? .other : .lan }
        return .other
    }

    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func ipv6String(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
    }
}

/// How Settings on the Mac and the pairing screens on the device name a kind of address (SF Symbols' names).
extension Endpoint.Kind {
    var title: String {
        switch self {
        case .lan: "Local network"
        case .tailscale: "Tailscale"
        case .other: "Other network"
        }
    }

    var symbol: String {
        switch self {
        case .lan: "wifi"
        case .tailscale: "point.3.filled.connected.trianglepath.dotted"
        case .other: "network"
        }
    }
}
