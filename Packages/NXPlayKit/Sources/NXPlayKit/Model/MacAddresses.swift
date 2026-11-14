import Darwin
import Foundation

/// The addresses this Mac's server can be reached at, for Settings › Devices and the pairing QR code: the interfaces'
/// own addresses (a .local name alone fails when mDNS doesn't reach the phone), the .local name, and Tailscale's.
enum MacAddresses {
    /// One address of one interface, as getifaddrs reports it.
    struct InterfaceAddress: Equatable, Sendable {
        let interface: String
        /// Numeric, without a %zone.
        let host: String
    }

    /// The up and running interfaces' IPv4 and IPv6 addresses, loopback left out.
    static func interfaceAddresses() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                let address = entry.ifa_addr
            else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let numeric = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let host = numeric.split(separator: "%").first.map(String.init) ?? ""
            found.append(InterfaceAddress(interface: String(validatingCString: entry.ifa_name) ?? "", host: host))
        }
        return found
    }

    /// Interfaces a phone never reaches the Mac through: Apple's peer-to-peer and internal links, tunnels' plumbing.
    static let ignoredPrefixes = ["awdl", "llw", "anpi", "ap", "gif", "stf", "lo", "XHC", "pktap", "iptap"]

    /// The endpoints to show and to put in a QR code, in the order an app should try them: the local network's IPv4,
    /// its .local name, its IPv6, then other addresses, then Tailscale's MagicDNS name and addresses. An address that
    /// can't be reached from another device (link-local, a VPN's other than Tailscale) is left out.
    static func endpoints(
        from addresses: [InterfaceAddress], localHostName: String?, tailscale: TailscaleStatus, port: UInt16
    ) -> [Endpoint] {
        var lan4: [Endpoint] = [], lan6: [Endpoint] = [], other: [Endpoint] = []
        var tailscale4: [Endpoint] = [], tailscale6: [Endpoint] = []
        var globalIPv6Interfaces: Set<String> = []
        func add(_ endpoint: Endpoint, interface: String?) {
            switch endpoint.kind {
            case .tailscale:
                if endpoint.isIPv6 { tailscale6.append(endpoint) } else { tailscale4.append(endpoint) }
            case .lan:
                if endpoint.isIPv6 { lan6.append(endpoint) } else { lan4.append(endpoint) }
            case .other:
                // a public IPv6 address: one per interface (the others are temporary ones that change daily)
                if endpoint.isIPv6, let interface, !globalIPv6Interfaces.insert(interface).inserted { return }
                other.append(endpoint)
            }
        }
        for address in addresses {
            guard !ignoredPrefixes.contains(where: address.interface.hasPrefix),
                let host = try? Endpoint.validatedHost(address.host)
            else { continue }
            let endpoint = Endpoint(validHost: host, port: port)
            // tunnels (utun) other than Tailscale: a work VPN's address isn't one the phone reaches
            if address.interface.hasPrefix("utun"), endpoint.kind != .tailscale { continue }
            // 169.254.x.x: only a cable straight to the Mac reaches it
            if !endpoint.isIPv6, host.hasPrefix("169.254.") { continue }
            add(endpoint, interface: address.interface)
        }
        for host in tailscale.addresses {
            if let host = try? Endpoint.validatedHost(host) { add(Endpoint(validHost: host, port: port), interface: nil) }
        }
        var names: [Endpoint] = []
        if let localHostName, !localHostName.isEmpty,
            let host = try? Endpoint.validatedHost("\(localHostName).local")
        {
            names.append(Endpoint(validHost: host, port: port))
        }
        var magicDNS: [Endpoint] = []
        if tailscale.isRunning, let name = tailscale.dnsName, let host = try? Endpoint.validatedHost(name) {
            magicDNS.append(Endpoint(validHost: host, port: port))
        }
        var seen: Set<Endpoint> = []
        let lanFirst = lan4 + names + lan6 + other
        return (lanFirst + magicDNS + tailscale4 + tailscale6).filter { seen.insert($0).inserted }
    }
}
