import Foundation

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
