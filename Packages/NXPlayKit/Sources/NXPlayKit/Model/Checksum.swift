import CryptoKit
import Foundation

/// A game file's published digest, by the algorithm its catalog names: `"sha256"`, as NX Play has always read, or
/// `"sha1"`, which is what archives such as the Internet Archive publish. A file is published only when the digest of
/// the very bytes that arrived matches. SHA-1 checks that the file is the one listed and arrived whole; it isn't
/// collision-resistant, so it says nothing about who made the file. NX Play names the algorithm wherever it shows a
/// file, so the player can tell which check a file got.
public struct Checksum: Sendable, Hashable {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha256, sha1

        /// As people write it: SHA-256.
        public var label: String {
            switch self {
            case .sha256: "SHA-256"
            case .sha1: "SHA-1"
            }
        }

        var hexCount: Int {
            switch self {
            case .sha256: 64
            case .sha1: 40
            }
        }
    }

    public let algorithm: Algorithm
    /// Lowercased hex.
    public let hex: String

    /// Nil unless `hex` is the algorithm's number of ASCII hex digits.
    init?(_ algorithm: Algorithm, hex: String) {
        guard Catalog.isHex(hex, count: algorithm.hexCount) else { return nil }
        self.algorithm = algorithm
        self.hex = hex.lowercased()
    }

    /// What names a file in its entry, and what the iPhone app sends back to download it: a SHA-256 is its hex alone,
    /// as it always was; any other is `<algorithm>:<hex>`.
    public var id: String { algorithm == .sha256 ? hex : "\(algorithm.rawValue):\(hex)" }

    /// The checksum in a catalog's package, or a saved download's file: its `sha256` when it has one, else its `sha1`.
    /// A field that's there must be well formed, even the one not used: a bad one is refused, never passed over for
    /// the other. With neither, it's refused: NX Play doesn't download a file it can't check.
    static func read(_ object: [String: Any]) throws -> Checksum {
        var found: [Checksum] = []
        for algorithm in Algorithm.allCases where object[algorithm.rawValue] != nil {
            guard let text = object[algorithm.rawValue] as? String, let checksum = Checksum(algorithm, hex: text)
            else {
                throw Catalog.ParseError(
                    message: "\"\(algorithm.rawValue)\" isn't \(algorithm.hexCount) hex digits")
            }
            found.append(checksum)
        }
        guard let checksum = found.first else {
            throw Catalog.ParseError(message: "no \"sha256\" or \"sha1\" checksum")
        }
        return checksum
    }

    /// The field a saved download keeps it in: `["sha256": hex]` or `["sha1": hex]`, which `read` reads back.
    var field: [String: String] { [algorithm.rawValue: hex] }

    /// Works out a checksum of `algorithm` as bytes arrive, a chunk at a time.
    struct Hasher {
        private enum State {
            case sha256(SHA256)
            case sha1(Insecure.SHA1)
        }

        private var state: State
        let algorithm: Algorithm

        init(_ algorithm: Algorithm) {
            self.algorithm = algorithm
            switch algorithm {
            case .sha256: state = .sha256(SHA256())
            case .sha1: state = .sha1(Insecure.SHA1())
            }
        }

        mutating func update(data: Data) {
            switch state {
            case .sha256(var hasher):
                hasher.update(data: data)
                state = .sha256(hasher)
            case .sha1(var hasher):
                hasher.update(data: data)
                state = .sha1(hasher)
            }
        }

        func finalize() -> Checksum {
            let bytes: [UInt8] =
                switch state {
                case .sha256(let hasher): Array(hasher.finalize())
                case .sha1(let hasher): Array(hasher.finalize())
                }
            return Checksum(algorithm, hex: bytes.map { String(format: "%02x", $0) }.joined())!
        }
    }
}
