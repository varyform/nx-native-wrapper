import Foundation
import Network

/// What paired Macs say to each other for remote builds (Settings › Remote): a client lists the host's games and
/// their builds, and asks it to build or rebuild one, or to stop a build. Nothing else: a client can't play, change
/// settings or reach the host's files.
enum MacCall: Codable, Sendable {
    case pair(clientID: String, clientName: String, publicKey: Data)
    case hello(clientID: String, proof: Data, protocolVersion: Int)
    case unpair
    /// The games and their builds; `logs` asks for each listed game's log from the line the client has up to.
    case poll(logs: [String: Int])
    case build(game: String, rebuild: Bool)
    case cancel(game: String)
    case icon(game: String)
}

enum MacReply: Codable, Sendable {
    case ok
    case failure(String)
    case paired(hostID: String, hostName: String, publicKey: Data)
    case hello(hostID: String)
    case snapshot(MacSnapshot)
    case icon(Data?)
}

/// The host's library, as a client shows it.
public struct MacSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var games: [RemoteGame]
}

public struct RemoteGame: Codable, Sendable, Equatable, Identifiable {
    /// The game's id on the host (its folder's path there): what a call names it by.
    public var id: String
    public var name: String
    public var titleID: String?
    public var version: String?
    public var isExtracted: Bool
    public var isReady: Bool
    public var isKept: Bool
    public var canBuild: Bool
    public var canRebuild: Bool
    public var hasIcon: Bool
    /// Where the game is in a games folder that may be shared with the client (SharedFolders).
    public var shared: String?
    public var job: RemoteJob?
}

/// A build on the host, as far as a client mirrors it (Job+Mirror.swift).
public struct RemoteJob: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case extract, rebuild, play, other }

    public var id: UUID
    public var kind: Kind
    public var status: Job.Status
    public var progress: BuildProgress?
    public var note: String?
    public var warnings: [String]
    public var gameStarted: Bool
    /// The log's lines ever, and the ones from the line asked for (at most `MacWire.logChunk`).
    public var logTotal: Int
    public var logFrom: Int
    public var log: [LogLine]
}

struct MacRequestFrame: Codable, Sendable {
    let id: UInt64
    let call: MacCall
}

struct MacReplyFrame: Codable, Sendable {
    let id: UInt64
    let reply: MacReply
}

enum MacWire {
    static let protocolVersion = 1
    static let serviceType = "_nxplay-mac._tcp"
    static let instanceIDKey = "id"
    /// Above any snapshot or icon, while stopping a bad length from exhausting memory.
    static let maxFrameSize = 32 * 1024 * 1024
    /// The most log lines one poll carries for a game.
    static let logChunk = 2_000
}

public enum MacLinkError: LocalizedError, Equatable {
    /// The host doesn't accept this Mac's key or the code that was typed.
    case authenticationFailed
    case unreachable
    case disconnected
    case timedOut
    case unexpectedHost
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: "The code was wrong, or this Mac is no longer paired."
        case .unreachable: "That Mac can\u{2019}t be reached."
        case .disconnected: "The connection was lost."
        case .timedOut: "That Mac took too long to answer."
        case .unexpectedHost: "A different Mac answered than expected."
        case .rejected(let message): message
        }
    }

    init(_ error: NWError) {
        // -9864 is an unknown PSK identity, which the SDK has no public name for
        if case .tls(let status) = error, [errSSLPeerBadRecordMac, errSSLBadRecordMac, -9864].contains(status) {
            self = .authenticationFailed
        } else {
            self = .unreachable
        }
    }
}

/// Length-prefixed messages over an `NWConnection`. Each callback runs on the connection's own queue.
final class FrameConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.varyform.nxplay.mac-link")
    private let onFrame: @Sendable (Data) -> Void
    private let onClose: @Sendable (MacLinkError) -> Void
    private var isClosed = false

    init(
        _ connection: NWConnection, onFrame: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (MacLinkError) -> Void
    ) {
        self.connection = connection
        self.onFrame = onFrame
        self.onClose = onClose
    }

    func start(onReady: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                onReady()
                self?.receiveHeader()
            // a waiting connection would retry forever, but callers want an answer now and reconnect by
            // themselves; it's also how a rejected TLS key is reported
            case .waiting(let error), .failed(let error):
                self?.close(MacLinkError(error))
            case .cancelled:
                self?.close(.disconnected)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ payload: Data) {
        var frame = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        frame.append(payload)
        connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] error in
                if let error { self?.close(MacLinkError(error)) }
            })
    }

    func close(_ reason: MacLinkError = .disconnected) {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose(reason)
        }
    }

    private func receiveHeader() {
        receive(exactly: 4) { [weak self] header in
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard let self else { return }
            guard (1...MacWire.maxFrameSize).contains(length) else { return self.close(.disconnected) }
            self.receive(exactly: length) { [weak self] payload in
                self?.onFrame(payload)
                self?.receiveHeader()
            }
        }
    }

    private func receive(exactly count: Int, then handler: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            [weak self] data, _, isComplete, error in
            if let data, data.count == count {
                handler(data)
            } else if let error {
                self?.close(MacLinkError(error))
            } else if isComplete {
                self?.close(.disconnected)
            }
        }
    }
}

/// Resumes a continuation once, whichever of several callbacks gets there first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
