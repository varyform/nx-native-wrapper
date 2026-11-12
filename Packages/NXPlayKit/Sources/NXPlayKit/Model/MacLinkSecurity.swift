import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

/// The cryptography behind remote builds between Macs (Hive's design): traffic runs over TLS with pre-shared keys,
/// and pairing only decides what those keys are. Pairing happens in a TLS session keyed by the host's one-time code,
/// inside which the two sides do an X25519 exchange. The long-term key mixes both, so someone who records a pairing
/// and later cracks the code still can't work out the key, and interfering with one needs the code in real time.
enum MacLinkSecurity {
    /// The PSK identity a client uses to say it's pairing, rather than connecting as a known client.
    static let pairingIdentity = "pair"

    /// Crockford base32: no I, L, O or U, so a code survives being read aloud or misread.
    private static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let codeLength = 8
    private static let pairingIterations: UInt32 = 200_000

    /// 40 random bits, shown as `XXXX-XXXX`.
    static func makePairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<codeLength).map { _ in codeAlphabet.randomElement(using: &generator)! }
        return String(characters[..<4]) + "-" + String(characters[4...])
    }

    /// Forgives case, separators and the misreadings the alphabet was designed around.
    static func normalizedCode(_ code: String) -> String {
        String(
            code.uppercased().compactMap { character -> Character? in
                switch character {
                case "O": "0"
                case "I", "L": "1"
                case _ where codeAlphabet.contains(character): character
                default: nil
                }
            })
    }

    /// Stretched, because a code is far weaker than a real key and a TLS handshake lets anyone who recorded it test
    /// guesses offline. Slow on purpose: callers keep it off the main actor.
    static func pairingKey(code: String, hostID: String) -> Data {
        let password = Array(normalizedCode(code).utf8)
        let salt = Array("nxplay-pair-v1:\(hostID)".utf8)
        var key = Data(count: 32)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { output in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password.map { Int8(bitPattern: $0) }, password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                pairingIterations,
                output.bindMemory(to: UInt8.self).baseAddress, keyCount)
        }
        precondition(status == kCCSuccess, "PBKDF2 can't fail with valid parameters")
        return key
    }

    static func longTermKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data, pairingKey: Data,
        clientID: String, hostID: String
    ) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: pairingKey,
            sharedInfo: Data("nxplay-remote-v1|\(clientID)|\(hostID)".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Ties a connection to one paired client, because TLS doesn't report which key was used.
    static func clientProof(key: Data, clientID: String) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Data("nxplay-hello-v1|\(clientID)".utf8), using: SymmetricKey(data: key)))
    }

    static func isValidClientProof(_ proof: Data, key: Data, clientID: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: Data("nxplay-hello-v1|\(clientID)".utf8), using: SymmetricKey(data: key))
    }

    /// TLS 1.2 because Network.framework's PSK support doesn't work with 1.3.
    static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(identity.utf8)))
        }
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
