import Foundation

/// Where the saved pairing code may go without asking the player again.
///
/// NX Play talks plain HTTP and the Mac has no key the app could check, so nothing an address answers proves it is
/// the paired Mac: its ID is public (Bonjour's TXT record, `/v1/hello`), and anything on the network can repeat it.
/// So the saved code goes only to addresses the player confirmed when pairing: the pairing link's (shown before
/// pairing), the one typed in, or those of the Mac picked from the list. Bonjour finding the Mac's ID elsewhere is
/// only a hint: the library says so and offers to pair again (QR code, or the address and code typed in), which sends
/// the code the player gives there, never the saved one.
///
/// What this assumes: the networks of the confirmed addresses. On Wi-Fi the code travels in clear, so whoever can
/// read that network's traffic, or take over a confirmed address there, can learn it, as with a code typed by hand.
/// Over Tailscale, WireGuard encrypts the traffic and the 100.x addresses belong to the tailnet's own devices, but
/// only while Tailscale is connected on this device: without it, a 100.x address is someone else's network.
enum PairingTrust {
    /// The addresses to try the saved code at when the preferred one stops answering: the other confirmed ones.
    static func reconnectCandidates(_ paired: PairedMac) -> [Endpoint] {
        Array(paired.endpoints.dropFirst())
    }

    /// Addresses where Bonjour sees the paired Mac's ID but that the player never confirmed: the code doesn't go
    /// there by itself.
    static func unconfirmedAddresses(of paired: PairedMac?, found: [(macID: String?, endpoints: [Endpoint])]) -> [Endpoint] {
        guard let paired, let id = paired.macID else { return [] }
        var addresses: [Endpoint] = []
        for mac in found where mac.macID == id {
            for endpoint in mac.endpoints where !paired.endpoints.contains(endpoint) && !addresses.contains(endpoint) {
                addresses.append(endpoint)
            }
        }
        return addresses
    }
}

/// Pairing with a Mac at one of several addresses, and finding it again at another later (Launcher). The code goes
/// only to an address that answered `/v1/hello` as NX Play on the expected Mac, so a stale address, another Mac or
/// something else answering by mistake never receives it (it doesn't stop an impostor: see PairingTrust). Cancelled,
/// it stops before sending the code anywhere else. On the main actor, with the app's state; the requests themselves
/// run elsewhere.
@MainActor enum PairingAttempt {
    struct Success: Sendable {
        let endpoint: Endpoint
        /// The Mac's ID: from /v1/hello, else from /v1/info; nil from a Mac before QR pairing.
        let macID: String?
        let info: MacInfo
        let devices: [RemoteDevice]
    }

    /// Whether NX Play on the right Mac answers at `endpoint`, asked without the code. `expectedID` nil takes any NX
    /// Play, an older one included (an address typed in, or a Mac before QR pairing).
    static func check(_ endpoint: Endpoint, expectedID: String?) async throws -> Result<String?, PairingFailure> {
        switch try await MacClient(endpoint: endpoint, token: "").hello() {
        case .nxplay(let hello):
            if let expectedID, hello.id != expectedID { return .failure(.otherMac(endpoint)) }
            return .success(hello.id)
        case .olderNXPlay:
            // a link names a Mac that has /v1/hello: an older NX Play there is another Mac
            return expectedID == nil ? .success(nil) : .failure(.otherMac(endpoint))
        case .notNXPlay:
            return .failure(.notNXPlay(endpoint))
        }
    }

    /// Tries the addresses in order; the first where the right NX Play answers and takes the code wins. A wrong code
    /// stops it (it's wrong at every address). The failures come back in words, `describe` putting network errors.
    static func run(
        endpoints: [Endpoint], token: String, expectedID: String?,
        describe: (any Error, Endpoint) -> String
    ) async -> Result<Success, PairingFailures> {
        var failures: [String] = []
        addresses: for endpoint in endpoints {
            guard !Task.isCancelled else { break }
            do {
                let macID: String?
                switch try await check(endpoint, expectedID: expectedID) {
                case .success(let id): macID = id
                case .failure(let failure):
                    failures.append(failure.message)
                    continue
                }
                // cancelled while asking: the code doesn't go out
                try Task.checkCancellation()
                let client = MacClient(endpoint: endpoint, token: token)
                let info = try await client.info()
                try Task.checkCancellation()
                let devices = try await client.devices()
                return .success(Success(endpoint: endpoint, macID: macID ?? info.id, info: info, devices: devices))
            } catch _ where Task.isCancelled {
                break addresses
            } catch let failure as MacClient.Failure where failure.status == 401 {
                failures.append(failure.message)
                break addresses
            } catch {
                failures.append(describe(error, endpoint))
            }
        }
        return .failure(PairingFailures(messages: failures))
    }
}

enum PairingFailure: Error, Equatable {
    case otherMac(Endpoint)
    case notNXPlay(Endpoint)

    var message: String {
        switch self {
        case .otherMac(let endpoint): "\(endpoint.display) is NX Play on another Mac."
        case .notNXPlay(let endpoint): "\(endpoint.display) answered, but it isn't NX Play."
        }
    }
}

struct PairingFailures: Error, Equatable {
    let messages: [String]

    /// One failure as it is; several as a short list.
    var text: String {
        messages.count == 1 ? messages[0] : messages.prefix(3).map { "• \($0)" }.joined(separator: "\n")
    }
}
