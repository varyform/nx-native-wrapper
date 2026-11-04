import Foundation

/// A repository's catalog: a static JSON file the player hosts on their own server (Catalog/README.md has the schema
/// and a generator). Only data: names, title IDs, versions and the game files with their size and SHA-256 (or the SHA-1
/// an archive publishes: Checksum). Nothing in it runs. An entry or a package that doesn't check out is left out with the reason, so one bad line doesn't hide
/// the rest of the catalog.
///
///     {"nxplayCatalog": 1, "name": "Shelf", "entries": [
///       {"id": "example", "name": "Example", "titleID": "0100000000010000", "version": "1.0.2",
///        "packages": [{"kind": "base", "filename": "Example.nsp", "url": "files/Example.nsp",
///                      "bytes": 1048576, "sha256": "<64 hex>", "titleID": "0100000000010000", "version": 0}]}]}
public struct Catalog: Sendable, Equatable {
    public static let formatVersion = 1
    /// A catalog bigger than this is refused before it is read: tens of thousands of entries fit well within it.
    static let maxBytes = 16 * 1024 * 1024
    static let maxEntries = 50_000
    /// A game's base, its updates and its DLC: the games with the most DLC have a few hundred.
    static let maxPackagesPerEntry = 2_000
    /// Across the catalog, so reading one stays quick even at the size limit.
    static let maxPackages = 200_000
    /// The largest game file a catalog may list: the biggest cartridges are 32 GB.
    static let maxPackageBytes: Int64 = 64 * 1024 * 1024 * 1024

    public let name: String
    public let entries: [CatalogEntry]
    /// What was left out and why, one line each.
    public let issues: [String]

    public struct ParseError: Error, Equatable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }

        static func text(_ error: any Error) -> String {
            (error as? ParseError)?.message ?? error.localizedDescription
        }
    }

    /// The catalog in `data`, fetched from `base` (relative package URLs resolve against it).
    public static func parse(_ data: Data, base: URL) throws -> Catalog {
        guard data.count <= maxBytes else {
            throw ParseError(message: "The catalog is larger than \(maxBytes / 1024 / 1024) MB")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(message: "The catalog isn't a JSON object")
        }
        guard let format = object["nxplayCatalog"] as? Int else {
            throw ParseError(message: "Not an NX Play catalog: it has no \"nxplayCatalog\" version")
        }
        guard format == formatVersion else {
            throw ParseError(
                message: "The catalog is format \(format); this NX Play reads format \(formatVersion)")
        }
        guard let rawEntries = object["entries"] as? [Any] else {
            throw ParseError(message: "The catalog has no \"entries\" list")
        }
        guard rawEntries.count <= maxEntries else {
            throw ParseError(message: "The catalog lists more than \(maxEntries) entries")
        }
        let packageCount = rawEntries.reduce(0) { count, raw in
            count + (((raw as? [String: Any])?["packages"] as? [Any])?.count ?? 0)
        }
        guard packageCount <= maxPackages else {
            throw ParseError(message: "The catalog lists more than \(maxPackages) files")
        }
        var entries: [CatalogEntry] = []
        var issues: [String] = []
        var seen: Set<String> = []
        for (index, raw) in rawEntries.enumerated() {
            do {
                let entry = try CatalogEntry(raw, base: base)
                guard seen.insert(entry.id.lowercased()).inserted else {
                    throw ParseError(message: "a second entry with id \(entry.id)")
                }
                entries.append(entry)
            } catch {
                issues.append("Entry \(index + 1): \(Catalog.ParseError.text(error))")
            }
        }
        let name = (object["name"] as? String).map(Self.clean) ?? ""
        return Catalog(name: String(name.prefix(100)), entries: entries, issues: issues)
    }

    /// `parse`, away from the main actor: a big catalog takes a moment to read.
    @concurrent public static func load(_ data: Data, base: URL) async throws -> Catalog {
        try parse(data, base: base)
    }

    /// The base game's title ID for a package's own (an update's ends in 800, a DLC's is above its base game's), as
    /// nxplay_catalog.py works it out.
    static func baseTitleID(_ titleID: String) -> String? {
        guard isTitleID(titleID), let value = UInt64(titleID, radix: 16) else { return nil }
        let low = value & 0xFFF
        let base = low == 0 ? value : low == 0x800 ? value & ~0xFFF : (value & ~0xFFF) &- 0x1000
        return String(format: "%016llX", base)
    }

    /// Whitespace runs as one space, control characters out.
    static func clean(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isTitleID(_ text: String) -> Bool { isHex(text, count: 16) }

    /// ASCII hex only (Character.isHexDigit takes full-width digits too).
    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count
            && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

public struct CatalogEntry: Sendable, Equatable, Identifiable {
    /// Unique in its catalog: the entry's `id`, else its title ID.
    public let id: String
    public let name: String
    /// The base game's, uppercased.
    public let titleID: String
    /// As the catalog shows it ("1.0.2"); may be empty.
    public let version: String
    public let publisher: String
    public let summary: String
    public let packages: [CatalogPackage]
    /// Packages left out (an archive, a bad checksum field) and why: the entry still shows the rest.
    public let issues: [String]

    init(_ raw: Any, base: URL) throws {
        guard let object = raw as? [String: Any] else { throw Catalog.ParseError(message: "not an object") }
        guard let titleID = object["titleID"] as? String, Catalog.isTitleID(titleID) else {
            throw Catalog.ParseError(message: "no 16-digit hex \"titleID\"")
        }
        let name = Catalog.clean(object["name"] as? String ?? "")
        guard !name.isEmpty else { throw Catalog.ParseError(message: "no \"name\"") }
        let id = object["id"] as? String ?? titleID.uppercased()
        guard id.wholeMatch(of: #/[A-Za-z0-9._-]{1,64}/#) != nil else {
            throw Catalog.ParseError(message: "the id isn't 1 to 64 letters, digits, . _ or -")
        }
        guard let rawPackages = object["packages"] as? [Any], !rawPackages.isEmpty else {
            throw Catalog.ParseError(message: "no \"packages\"")
        }
        guard rawPackages.count <= Catalog.maxPackagesPerEntry else {
            throw Catalog.ParseError(message: "more than \(Catalog.maxPackagesPerEntry) packages")
        }
        var packages: [CatalogPackage] = []
        var issues: [String] = []
        var names: Set<String> = []
        var hashes: Set<Checksum> = []
        for (index, rawPackage) in rawPackages.enumerated() {
            do {
                let package = try CatalogPackage(rawPackage, base: base)
                guard !names.contains(package.filename.lowercased()) else {
                    throw Catalog.ParseError(message: "a second package named \(package.filename)")
                }
                guard !hashes.contains(package.checksum) else {
                    throw Catalog.ParseError(message: "the same file as another package")
                }
                names.insert(package.filename.lowercased())
                hashes.insert(package.checksum)
                packages.append(package)
            } catch {
                issues.append("Package \(index + 1): \(Catalog.ParseError.text(error))")
            }
        }
        guard !packages.isEmpty else {
            throw Catalog.ParseError(message: issues.first.map { "no usable package (\($0))" } ?? "no packages")
        }
        self.id = id
        self.name = String(name.prefix(200))
        self.titleID = titleID.uppercased()
        version = String(Catalog.clean(object["version"] as? String ?? "").prefix(32))
        publisher = String(Catalog.clean(object["publisher"] as? String ?? "").prefix(100))
        summary = String((object["description"] as? String ?? "").prefix(4000))
        self.packages = packages
        self.issues = issues
    }

    public var totalBytes: Int64 { packages.reduce(0) { $0 + $1.bytes } }
}

public struct CatalogPackage: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case base, update, dlc
    }

    public let kind: Kind
    /// A plain file name with a game file's extension: it becomes the file's name in the game's folder.
    public let filename: String
    /// Where the file is: http(s), resolved against the catalog's address.
    public let url: URL
    public let bytes: Int64
    /// The digest the catalog publishes for it, SHA-256 or SHA-1: what the downloaded bytes must match.
    public let checksum: Checksum
    public let titleID: String?
    /// The title version (65536 for v1.0.1's update…), when the catalog says.
    public let version: Int?

    /// The checksum names a package: unique in its entry.
    public var id: String { checksum.id }

    init(_ raw: Any, base: URL) throws {
        guard let object = raw as? [String: Any] else { throw Catalog.ParseError(message: "not an object") }
        guard let kindName = object["kind"] as? String, let kind = Kind(rawValue: kindName) else {
            throw Catalog.ParseError(message: "\"kind\" isn't base, update or dlc")
        }
        guard let filename = object["filename"] as? String else {
            throw Catalog.ParseError(message: "no \"filename\"")
        }
        if let problem = Self.filenameProblem(filename) { throw Catalog.ParseError(message: problem) }
        guard let link = object["url"] as? String, let url = URL(string: link, relativeTo: base)?.absoluteURL
        else { throw Catalog.ParseError(message: "no \"url\"") }
        if let problem = RepositoryAddress.problem(with: url) {
            throw Catalog.ParseError(message: "\(filename): \(problem)")
        }
        guard let bytes = (object["bytes"] as? NSNumber)?.int64Value, bytes > 0,
            bytes <= Catalog.maxPackageBytes,
            (object["bytes"] as? NSNumber).map({ !CFNumberIsFloatType($0) }) == true
        else { throw Catalog.ParseError(message: "\(filename): \"bytes\" isn't a whole number of bytes") }
        let checksum: Checksum
        do {
            checksum = try Checksum.read(object)
        } catch {
            throw Catalog.ParseError(message: "\(filename): \(Catalog.ParseError.text(error))")
        }
        let titleID = object["titleID"] as? String
        if let titleID, !Catalog.isTitleID(titleID) {
            throw Catalog.ParseError(message: "\(filename): \"titleID\" isn't 16 hex digits")
        }
        self.kind = kind
        self.filename = filename
        self.url = url
        self.bytes = bytes
        self.checksum = checksum
        self.titleID = titleID?.uppercased()
        version = (object["version"] as? NSNumber)?.intValue
    }

    static let gameExtensions: Set<String> = GameScanner.packageExtensions
    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "001",
    ]

    /// Why `name` can't be a file in a game's folder, nil when it can: one plain name (no folders, no `..`, not
    /// hidden), printable, with a game file's extension. Archives are refused before anything is downloaded: what's
    /// inside one can't be checked until it is unpacked, which would put unchecked files in the library.
    static func filenameProblem(_ name: String) -> String? {
        if name.isEmpty || name.utf8.count > 200 { return "the filename is empty or too long" }
        if name.contains("/") || name.contains("\\") || name.contains(":") {
            return "\(name): the filename has a folder in it"
        }
        if name.hasPrefix(".") || name == ".." { return "\(name): the filename is hidden" }
        if name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0 == "\u{0}"
        }) {
            return "the filename has control characters"
        }
        if name != name.trimmingCharacters(in: .whitespaces) {
            return "\(name): the filename starts or ends with a space"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return
                "\(name) is an archive. NX Play downloads only NSP, NSZ, XCI or XCZ files, which it checks before they go into your library. Host the game file itself."
        }
        guard gameExtensions.contains(ext) else {
            return "\(name) isn't an NSP, NSZ, XCI or XCZ file"
        }
        return nil
    }
}

/// The addresses a repository's catalog and files may come from: HTTPS anywhere, plain HTTP only on the local
/// network (a `.local` name, a single-label name, localhost, or a loopback, private or link-local IP address). An IP
/// address out on the internet needs HTTPS like any other server: a token sent to it over plain HTTP could be read on
/// the way. No user name or password in the address: an access token goes in the Keychain instead.
public enum RepositoryAddress {
    public static func problem(with url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return "only http and https addresses work"
        }
        guard let host = url.host(), !host.isEmpty else { return "the address has no host" }
        if url.user != nil || url.password != nil {
            return "put the password or token in the Access token field, not in the address"
        }
        if scheme == "http", !isLocal(host) {
            return "plain http works only on the local network: use https for \(host)"
        }
        return nil
    }

    /// Query keys that look like credentials: they'd be saved with the address in NX Play's settings.
    /// Each name is read from the query as written, decoded as many times as it takes (`%74oken` and `%2574oken` are
    /// `token`) with malformed escapes left as they are: one bad escape elsewhere in the query mustn't hide a name,
    /// as the system's own query parsing gives no names at all then. A name with an encoded "=" (`token%3D…`) carries
    /// its value: only the part before the "=" is quoted. Read as redaction reads it (`ControlRedaction`, one budget):
    /// an address redaction couldn't read to the end, and would hide whole, is refused rather than saved.
    public static func secretQueryProblem(_ url: URL) -> String? {
        let query = url.query(percentEncoded: true) ?? ""
        let unreadable =
            "the address is encoded over and over, which may hide a credential: put it in the Access token field"
        if ControlRedaction.exhausts(url.absoluteString) { return unreadable }
        let budget = ControlRedaction.Budget(for: query)
        let names = query.split(separator: "&").map {
            String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        for name in names {
            guard let layers = try? ControlRedaction.decodedLayers(name, budget: budget) else { return unreadable }
            // the most decoded first: what is quoted stops at its "=", however the "=" was encoded
            for layer in layers.reversed() {
                let shown = String(layer.prefix { $0 != "=" })
                if shown.lowercased().contains(#/token|key|sig|auth|pass|secret|credential/#) {
                    return "the address has “\(shown)” in it, which looks like a credential: put it in the Access token field"
                }
            }
        }
        return nil
    }

    /// An address is checked as an IP address first (a v6 one has no dots, so it would pass for a single-label name),
    /// then as a name. Numbers that aren't a plain dotted IPv4 address (`16843009`, `0x7f.1`, `010.0.0.1`) are
    /// refused: the system may read them as an address on the internet.
    static func isLocal(_ host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") {
            // a link-local address's zone: fe80::1%en0, written fe80::1%25en0 in a URL
            let address = String(host.prefix { $0 != "%" })
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
            return isLocal(v6)
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            // written the plain way (no leading zeros), as nxplay_catalog.py accepts it too
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &text, socklen_t(text.count)) != nil,
                String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == host
            else { return false }
            return isLocal(v4)
        }
        var loose = in_addr()
        if inet_aton(host, &loose) == 1 { return false }
        return host == "localhost" || host.hasSuffix(".local") || (!host.isEmpty && !host.contains("."))
    }

    /// 127/8 loopback, 10/8, 172.16/12 and 192.168/16 private, 169.254/16 link-local.
    static func isLocal(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let (a, b) = (value >> 24, (value >> 16) & 0xFF)
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254)
    }

    /// ::1 loopback, fc00::/7 unique local, fe80::/10 link-local, and an IPv4 address mapped into v6 (::ffff:a.b.c.d)
    /// by the v4 rules.
    static func isLocal(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            var v4 = in_addr()
            v4.s_addr = bytes[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return isLocal(v4)
        }
        return false
    }
}

/// Scheme, host and port: a token is sent only to the origin of the catalog it was saved for.
public struct RepositoryOrigin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// As people write it: https://nas.local:8443.
    public var text: String {
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)" + (standard ? "" : ":\(port)")
    }
}
