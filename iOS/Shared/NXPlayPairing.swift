import Foundation

/// Pairing NX Play for iPhone and iPad with a Mac: the addresses the Mac is reached at, and the link a QR code carries
/// (`nxplay://pair?v=1&id=…&n=…&c=…&e=…`). This one file is shared: the Mac (NXPlayKit, through a symlink) makes the
/// link and the iOS app (iOS/Shared) reads it, so both sides agree on the format.
///
/// The link holds the pairing code, so it's a credential: whoever has it can use the Mac's API, as with the code typed
/// by hand. Nothing here logs it, and `PairingError` never repeats it.
enum NXPlayPairing {
    static let scheme = "nxplay"
    static let action = "pair"
    /// The link's format. A Mac with a newer one makes links an older app refuses with "update NX Play".
    static let version = 1
    /// The port the Mac listens on unless Settings › Devices says another.
    static let defaultPort: UInt16 = 47_474
    /// A link longer than this isn't read at all: a QR code of the Mac's has a few hundred characters.
    static let maxLinkLength = 1_024
    static let maxEndpoints = 8
    static let maxNameLength = 64
    /// The letters and digits the Mac's codes are made of (Library.newRemoteToken): no 0/o, 1/l/i.
    static let codeAlphabet = Set("abcdefghjkmnpqrstuvwxyz23456789")
    /// What `GET /v1/hello` answers as `app`: the one request that needs no code, so the app can check it reached
    /// NX Play, and the Mac it expects, before it sends the code.
    static let helloApp = "nxplay"

    /// A code as typed: spaces around it dropped, lowercased (the Mac's codes are lowercase).
    static func normalizedCode(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A Mac's name as a link carries it, and as `PairingLink.parse` accepts it: without control or format characters
    /// (a joiner, a direction mark), without spaces around it, and at most `maxNameLength` characters.
    static func cleanName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.unicodeScalars.filter { !isHiddenInName($0) })
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isHiddenInName(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
    }

    /// Three groups of four from `codeAlphabet`, as the Mac makes them.
    static func isValidCode(_ code: String) -> Bool {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 3
            && groups.allSatisfy { $0.count == 4 && $0.allSatisfy(codeAlphabet.contains) }
    }
}

/// What a link or an address got wrong, in words for the player. It never quotes the pairing code.
enum PairingError: Error, Equatable, LocalizedError {
    case notAPairingLink
    case tooLong
    case newerVersion
    case malformed(String)
    case badAddress(String)
    case badPort
    case noAddresses

    var errorDescription: String? {
        switch self {
        case .notAPairingLink: "That isn't an NX Play pairing code. Use the QR code in NX Play › Settings › Devices on the Mac."
        case .tooLong: "That pairing link is too long to be NX Play's."
        case .newerVersion: "That pairing code is from a newer NX Play: update NX Play on this device, then try again."
        case .malformed(let what): "That pairing link is damaged (\(what)). Show the QR code on the Mac again."
        case .badAddress(let why): why
        case .badPort: "The port must be a number from 1 to 65535."
        case .noAddresses: "That pairing link has no address for the Mac."
        }
    }
}

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

/// A pairing link: which Mac (a random ID it keeps, also in its Bonjour TXT record), its name, its pairing code, and the
/// addresses it was reached at when the QR code was made, in the order to try them.
struct PairingLink: Equatable, Sendable {
    let macID: String
    let name: String
    let code: String
    let endpoints: [Endpoint]

    init(macID: String, name: String, code: String, endpoints: [Endpoint]) {
        self.macID = macID
        self.name = name
        self.code = code
        self.endpoints = endpoints
    }

    /// nxplay://pair?v=1&id=<Mac ID>&n=<name>&c=<code>&e=<host:port>&e=…; nil when it would be longer than `parse`
    /// reads (`NXPlayPairing.maxLinkLength` bytes): `fitting` makes a link that fits.
    var url: URL? {
        var components = URLComponents()
        components.scheme = NXPlayPairing.scheme
        components.host = NXPlayPairing.action
        components.queryItems =
            [
                URLQueryItem(name: "v", value: String(NXPlayPairing.version)),
                URLQueryItem(name: "id", value: macID),
                URLQueryItem(name: "n", value: String(name.prefix(NXPlayPairing.maxNameLength))),
                URLQueryItem(name: "c", value: code),
            ] + endpoints.prefix(NXPlayPairing.maxEndpoints).map { URLQueryItem(name: "e", value: $0.display) }
        // `[`, `]` and `:` are left alone in a query; `+` reads as a space to some parsers
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "[", with: "%5B")
            .replacingOccurrences(of: "]", with: "%5D")
        guard let url = components.url, url.absoluteString.utf8.count <= NXPlayPairing.maxLinkLength else { return nil }
        return url
    }

    /// The link the Mac shows and copies, made so that `parse` reads it back as it is. The name is cleaned as `parse`
    /// wants it ("Mac" when nothing is left). When the link would be too long, the name gets shorter first, down to one
    /// character, because only the addresses matter for pairing; then the last addresses are left out, because they
    /// are tried last. Nil without an address, or when even the first address doesn't fit.
    static func fitting(macID: String, name: String, code: String, endpoints: [Endpoint]) -> PairingLink? {
        var name = NXPlayPairing.cleanName(name)
        if name.isEmpty { name = "Mac" }
        var unique: [Endpoint] = []
        for endpoint in endpoints where !unique.contains(endpoint) { unique.append(endpoint) }
        var chosen = Array(unique.prefix(NXPlayPairing.maxEndpoints))
        while !chosen.isEmpty {
            let link = PairingLink(macID: macID, name: name, code: code, endpoints: chosen)
            if link.url != nil { return link }
            if name.count > 1 {
                name = String(name.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { name = "Mac" }
            } else {
                chosen.removeLast()
            }
        }
        return nil
    }

    /// Whether the text is meant as a pairing link at all (a QR code of something else isn't).
    static func looksLikeLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .hasPrefix("\(NXPlayPairing.scheme)://\(NXPlayPairing.action)")
    }

    /// Reads a link from a QR code, the clipboard or an opened URL. Anything that isn't exactly NX Play's format is
    /// refused: other schemes, a user, a fragment, unknown or repeated fields, bad addresses, a code of the wrong shape.
    static func parse(_ text: String) throws(PairingError) -> PairingLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= NXPlayPairing.maxLinkLength else { throw .tooLong }
        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == NXPlayPairing.scheme,
            components.host?.lowercased() == NXPlayPairing.action,
            components.user == nil, components.password == nil, components.port == nil,
            components.fragment == nil, components.path.isEmpty || components.path == "/"
        else { throw .notAPairingLink }
        let items = components.queryItems ?? []
        guard items.count <= 4 + NXPlayPairing.maxEndpoints else { throw .malformed("too many fields") }
        var single: [String: String] = [:]
        var addresses: [String] = []
        for item in items {
            let value = item.value ?? ""
            switch item.name {
            case "e": addresses.append(value)
            case "v", "id", "n", "c":
                guard single.updateValue(value, forKey: item.name) == nil else { throw .malformed("a repeated field") }
            default: throw .malformed("an unknown field")
            }
        }
        guard let versionText = single["v"], let version = Int(versionText), version > 0 else {
            throw .malformed("no version")
        }
        guard version == NXPlayPairing.version else { throw version > NXPlayPairing.version ? .newerVersion : .malformed("an old version") }
        guard let id = single["id"].flatMap(UUID.init(uuidString:)) else { throw .malformed("no Mac ID") }
        let name = (single["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= NXPlayPairing.maxNameLength,
            !name.unicodeScalars.contains(where: NXPlayPairing.isHiddenInName)
        else { throw .malformed("the Mac's name") }
        let code = NXPlayPairing.normalizedCode(single["c"] ?? "")
        guard NXPlayPairing.isValidCode(code) else { throw .malformed("the pairing code") }
        guard !addresses.isEmpty else { throw .noAddresses }
        guard addresses.count <= NXPlayPairing.maxEndpoints else { throw .malformed("too many addresses") }
        var endpoints: [Endpoint] = []
        for address in addresses {
            let endpoint = try Endpoint.parse(address, defaultPort: nil)
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
        return PairingLink(macID: id.uuidString, name: name, code: code, endpoints: endpoints)
    }
}

/// `GET /v1/hello`'s answer: NX Play, its API version, and the Mac's ID. No code is needed, and nothing else is told.
struct PairingHello: Codable, Equatable, Sendable {
    let app: String
    let api: Int
    let id: String
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
