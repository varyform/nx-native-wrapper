import SwiftUI

/// Pairs with a Mac: by its QR code (or the link pasted), by picking it from the Macs Bonjour finds on this network,
/// or by an address typed in (a local address or name, a Tailscale name or 100.x address, IPv6), with the code NX Play
/// shows in Settings › Devices › iPhone & iPad App.
struct PairView: View {
    @Environment(Launcher.self) private var launcher
    @State private var chosen: MacFinder.Found.ID?
    @State private var address = ""
    @State private var port = String(NXPlayPairing.defaultPort)
    @State private var code = ""
    @State private var addressProblem: String?
    @State private var linkProblem: String?

    var body: some View {
        @Bindable var launcher = launcher
        NavigationStack {
            Form {
                Section {
                    Button {
                        launcher.showsScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder").font(.headline)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in paste(strings.first ?? "") }
                    }
                    .labelStyle(.titleAndIcon)
                    if let linkProblem {
                        Label(linkProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Easiest")
                } footer: {
                    Text(
                        "On the Mac: NX Play › Settings › Devices › Show QR Code…. It works at home and over Tailscale. Copy Link there pastes here through Universal Clipboard."
                    )
                }
                MacsSection(chosen: $chosen, onChoose: { address = "" })
                Section {
                    TextField("192.168.1.20, mac.local or mac.tailnet.ts.net", text: $address)
                        .textContentType(.URL).keyboardType(.URL)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: address) {
                            addressProblem = nil
                            if !address.isEmpty { chosen = nil }
                        }
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    if let addressProblem {
                        Label(addressProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Or by address")
                } footer: {
                    Text(
                        "NX Play › Settings › Devices lists the Mac's addresses. Over Tailscale, with Tailscale on here too: its MagicDNS name or 100.x address. IPv6 goes in brackets with a port: [fd7a::1]:47474."
                    )
                }
                Section {
                    TextField("abcd-efgh-jkmn", text: $code)
                        .font(.body.monospaced()).privacySensitive()
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Shown in the Mac's Settings › Devices, under the address.")
                }
                Section {
                    Button(action: pair) {
                        HStack {
                            Text("Pair")
                            if launcher.isPairing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled((chosen == nil && address.isEmpty) || code.isEmpty || launcher.isPairing)
                }
            }
            .navigationTitle("Pair with a Mac")
        }
        .onAppear { launcher.finder.start() }
        .onDisappear { launcher.finder.stop() }
    }

    private func paste(_ text: String) {
        do {
            launcher.pendingPairing = PendingPairing(link: try PairingLink.parse(text))
            linkProblem = nil
        } catch {
            linkProblem = error.localizedDescription
        }
    }

    private func pair() {
        let endpoints: [Endpoint]
        var name = ""
        var expectedID: String?
        if let chosen, address.isEmpty, let mac = launcher.finder.found.first(where: { $0.id == chosen }) {
            endpoints = mac.endpoints
            name = mac.name
            expectedID = mac.macID
        } else {
            guard let defaultPort = UInt16(port.trimmingCharacters(in: .whitespaces)), defaultPort > 0 else {
                addressProblem = PairingError.badPort.localizedDescription
                return
            }
            do {
                endpoints = [try Endpoint.parse(address, defaultPort: defaultPort)]
            } catch {
                addressProblem = error.localizedDescription
                return
            }
        }
        Task {
            await launcher.pair(name: name, endpoints: endpoints, token: code, expectedID: expectedID)
        }
    }
}

/// The Macs Bonjour finds on this network, and what to do when it finds none or isn't allowed to look.
private struct MacsSection: View {
    @Environment(Launcher.self) private var launcher
    @Binding var chosen: MacFinder.Found.ID?
    let onChoose: () -> Void

    var body: some View {
        let finder = launcher.finder
        Section {
            switch finder.status {
            case .denied:
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NX Play isn't allowed on the local network, so it can't find the Mac.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .foregroundStyle(.orange)
            case .failed(let why):
                Label("Can't look on this network now (\(why)). Trying again…", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            case .idle, .searching:
                if finder.found.isEmpty {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let long = finder.searchingSince.map { context.date.timeIntervalSince($0) > 8 } ?? false
                        Label(
                            long
                                ? "No Mac found yet. Is this \(UIDevice.current.model) on the Mac's Wi-Fi, with NX Play open there? Away from it, scan the QR code instead."
                                : "Looking for NX Play on this network…",
                            systemImage: long ? "questionmark.circle" : "wifi")
                        .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(finder.found) { mac in
                Button {
                    chosen = mac.id
                    onChoose()
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading) {
                                Text(mac.name)
                                Text(mac.endpoints.first?.display ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                        Spacer()
                        if chosen == mac.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } header: {
            Text("Macs on this network")
        } footer: {
            Text(
                "Found over Bonjour on the same local network only: it doesn't reach a Mac over Tailscale. On the Mac: Settings › Devices, with \u{201C}Let iPhones and iPads install games from this Mac\u{201D} on."
            )
        }
    }
}

/// A scanned, pasted or opened pairing link: which Mac and where, for the player to confirm. The code isn't shown.
struct PairingLinkSheet: View {
    let pending: PendingPairing
    @Environment(Launcher.self) private var launcher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let link = pending.link
        NavigationStack {
            Form {
                Section {
                    Label(link.name, systemImage: "desktopcomputer").font(.headline)
                    if let current = launcher.mac, current.macID != link.macID {
                        Label(
                            "This replaces the pairing with \(current.name) once it works.",
                            systemImage: "arrow.triangle.swap")
                        .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(link.endpoints, id: \.self) { endpoint in
                        Label {
                            HStack {
                                Text(verbatim: endpoint.display).monospaced()
                                Spacer()
                                Text(endpoint.kind.title).foregroundStyle(.secondary).font(.caption)
                            }
                        } icon: {
                            Image(systemName: endpoint.kind.symbol)
                        }
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text(
                        "Tried in this order. Later, NX Play sends the code only to these addresses; at a new one, pair again. On Wi-Fi the code travels unencrypted, so pair on a network you trust. Over Tailscale it's encrypted, with Tailscale on here too."
                    )
                }
            }
            .navigationTitle("Pair with This Mac?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // stops the pairing under way: a late yes from the Mac changes nothing
                    Button("Cancel", systemImage: "xmark") {
                        launcher.cancelPairing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if launcher.isPairing {
                        ProgressView()
                    } else {
                        Button("Pair") {
                            Task {
                                if await launcher.pair(with: link) { dismiss() }
                            }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(launcher.isPairing)
        // gone any other way (another link replaced it): its pairing ends with it
        .onDisappear { launcher.cancelPairing() }
    }
}


/// An iPhone or iPad can't learn its own UDID, so it's picked once from the devices the Mac reaches.
struct DevicePickerView: View {
    @Environment(Launcher.self) private var launcher

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(launcher.devices.sorted { ($0.isThisKind ? 0 : 1, $0.name) < ($1.isThisKind ? 0 : 1, $1.name) }) {
                        device in
                        Button {
                            launcher.choose(device)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text("\(device.model) · \(device.isPad ? "iPadOS" : "iOS") \(device.os)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(
                        "Not listed? Pair this \(UIDevice.current.model) with Xcode on the Mac (Window › Devices and Simulators), tick Connect via network, and turn on Developer Mode."
                    )
                }
            }
            .navigationTitle("Which one is this \(UIDevice.current.model)?")
            .toolbar {
                Button("Refresh") { Task { await launcher.loadDevices() } }
                Button("Unpair", role: .destructive) { launcher.unpair() }
            }
            .refreshable { await launcher.loadDevices() }
        }
        .task { await launcher.loadDevices() }
    }
}

extension RemoteDevice {
    var isPad: Bool { model.hasPrefix("iPad") }
    /// An iPad when this is one, an iPhone when this is one: listed first, as the likely answer.
    @MainActor var isThisKind: Bool { model.hasPrefix(UIDevice.current.model) }
}
