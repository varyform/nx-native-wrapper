import Foundation

/// Pairing NX Play for iPhone and iPad with a Mac: the addresses the Mac is reached at, and the link a QR code carries
/// (`nxplay://pair?v=1&id=…&n=…&c=…&e=…`). The files in iOS/Shared (this one, Endpoint.swift, PairingLink.swift) are
/// shared: the Mac (NXPlayKit, through symlinks) makes the link and the iOS app reads it, so both sides agree on the
/// format.
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

/// `GET /v1/hello`'s answer: NX Play, its API version, and the Mac's ID. No code is needed, and nothing else is told.
struct PairingHello: Codable, Equatable, Sendable {
    let app: String
    let api: Int
    let id: String
}
