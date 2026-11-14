import Foundation

extension MacClient {
    /// A failure in words that say what to do: the Mac's own message, else what the network said, with what to
    /// check for this kind of address. `localNetworkDenied`: Bonjour said NX Play may not use the local network.
    static func describe(_ error: any Error, at endpoint: Endpoint, localNetworkDenied: Bool, device: String) -> String {
        if let failure = error as? Failure { return failure.message }
        let permission =
            "NX Play isn't allowed on the local network: turn it on in Settings › Privacy & Security › Local Network › NX Play, then try again."
        guard let error = error as? URLError else { return error.localizedDescription }
        let address = endpoint.display
        switch (error.code, endpoint.kind) {
        case (.appTransportSecurityRequiresSecureConnection, _):
            return "iOS allows NX Play's plain HTTP only to IP addresses, local names (.local) and Tailscale names (.ts.net): type the Mac's address instead of \(endpoint.host)."
        case (.cannotFindHost, .tailscale), (.dnsLookupFailed, .tailscale):
            return "Can't find \(endpoint.host): turn on Tailscale on this \(device), with MagicDNS, or type the Mac's 100.x address."
        case (.cannotFindHost, _), (.dnsLookupFailed, _):
            return "Can't find \(endpoint.host) from this network. Check this \(device) is on the Mac's network, or type the Mac's IP address (NX Play › Settings › Devices lists them)."
        case (.cannotConnectToHost, _):
            return "\(address) turned the connection down: check NX Play is open on the Mac with the iPhone & iPad App setting on, and that the port is the one Settings › Devices shows."
        case (.timedOut, .tailscale):
            return "No answer from \(address): check Tailscale is connected on this \(device) and on the Mac, and the Mac is awake."
        case (.timedOut, .lan), (.notConnectedToInternet, .lan), (.networkConnectionLost, .lan):
            if localNetworkDenied { return permission }
            return "No answer from \(address): check this \(device) is on the same Wi-Fi as the Mac, the Mac is awake, and NX Play may use the local network (Settings › Privacy & Security › Local Network)."
        case (.timedOut, _):
            return "No answer from \(address): check the Mac is awake and reachable from this network."
        case (.notConnectedToInternet, _):
            return "This \(device) isn't connected to a network."
        default:
            return "\(address): \(error.localizedDescription)"
        }
    }
}
