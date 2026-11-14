import SwiftUI

/// Settings › Devices › iPhone & iPad App: NX Play on an iPhone or iPad lists the games and asks this Mac to install
/// them there (Library+Remote.swift); Install NX Play puts the app itself there (Library+IOSApp.swift). The device
/// pairs by scanning the QR code (PairingQRView), by finding the Mac over Bonjour, or by an address typed in.
struct RemoteSettingsSection: View {
    @Environment(Library.self) private var library
    @State private var deviceID = ""
    @State private var showsQR = false

    var body: some View {
        @Bindable var library = library
        Section {
            Toggle("Let iPhones and iPads install games from this Mac", isOn: $library.remoteEnabled)
            if library.remoteEnabled {
                status
                LabeledContent("Pairing code") {
                    HStack {
                        Text(library.isScreenshot ? "abcd-efgh-jkmn" : library.remoteToken).monospaced()
                            .textSelection(.enabled)
                        Button("New Code") { library.renewRemoteToken() }
                    }
                }
                LabeledContent("Pair a device") {
                    Button("Show QR Code…", systemImage: "qrcode") { showsQR = true }
                        .disabled(library.remoteEndpoints.isEmpty)
                }
                RemotePortField()
            }
            if library.canInstallIOSApp { installRow }
        } header: {
            Text("iPhone & iPad App")
        } footer: {
            Text(
                "Scan the QR code with NX Play on the iPhone or iPad, or pick this Mac from the ones it finds on the local network and type the code. The device lists the games and asks for one: the Mac builds it, signed with the team above, and installs it over Wi-Fi or the cable. Pair the device with Xcode once, with Connect via network on, and keep the Mac awake. Install NX Play puts the app itself on the device, and renews it before it expires. A new code locks out devices that had the old one."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsQR) { PairingQRView() }
        if library.remoteEnabled { RemoteAddressesSection() }
    }

    /// Listening, and whether phones on this network can find the Mac over Bonjour yet.
    @ViewBuilder private var status: some View {
        if let problem = library.remoteProblem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else {
            switch library.remoteAdvertisement {
            case .advertised(let name):
                Label("Listening on port \(String(library.remotePort)). Devices on this network find it as \u{201C}\(name)\u{201D}.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .registering(let attempt):
                Label {
                    Text(
                        "Listening on port \(String(library.remotePort)), but macOS hasn't confirmed it on the local network yet\(attempt > 1 ? " (try \(attempt))" : ""), so devices may not find it by themselves. Pair with the QR code or an address below meanwhile."
                    )
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                }
                .foregroundStyle(.orange)
            case .off:
                if library.isScreenshot {
                    Label("Listening on port \(String(library.remotePort)). Devices on this network find it as \u{201C}Mac\u{201D}.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder private var installRow: some View {
        let devices = library.devices
        let running = library.iosAppInstall?.state == .running
        HStack {
            Picker("Install on", selection: $deviceID) {
                if devices.isEmpty { Text("No device found").tag("") }
                ForEach(devices) { Text($0.name).tag($0.id) }
            }
            .disabled(running)
            Button("Install NX Play") {
                if let device = devices.first(where: { $0.id == deviceID }) {
                    library.installIOSApp(on: device)
                }
            }
            .disabled(running || !devices.contains { $0.id == deviceID })
        }
        .onAppear(perform: pickDevice)
        .onChange(of: devices) { pickDevice() }
        if let install = library.iosAppInstall {
            HStack {
                switch install.state {
                case .running: ProgressView().controlSize(.small)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Text("\(install.device.name): \(install.status)").lineLimit(2)
            }
            if install.state == .failed {
                Text(install.lastLines.joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    /// The device NX Play last went to (renewing it is the usual reason to come back), else the first one.
    private func pickDevice() {
        guard !library.devices.contains(where: { $0.id == deviceID }) else { return }
        let last = library.iosAppInstall?.device.id
        deviceID = library.devices.first { $0.id == last }?.id ?? library.devices.first?.id ?? ""
    }
}

/// The port the server listens on: 47474 unless another app has it (a game engine's editor, say).
private struct RemotePortField: View {
    @Environment(Library.self) private var library
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        LabeledContent("Port") {
            HStack {
                TextField("Port", text: $text, prompt: Text(String(NXPlayPairing.defaultPort)))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                    .onSubmit(apply)
                Button("Apply", action: apply).disabled(text == String(library.remotePort))
                if library.remotePort != NXPlayPairing.defaultPort {
                    Button("Default") {
                        text = String(NXPlayPairing.defaultPort)
                        apply()
                    }
                }
                if invalid {
                    Text("1024–65535").foregroundStyle(.red).font(.caption)
                }
            }
        }
        .onAppear { text = String(library.remotePort) }
        .onChange(of: library.remotePort) { text = String(library.remotePort) }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), (1024...65535).contains(value) else {
            invalid = true
            return
        }
        invalid = false
        library.setRemotePort(value)
    }
}

/// Every address this Mac is reached at, and Tailscale: what to type on the device when it doesn't find the Mac.
private struct RemoteAddressesSection: View {
    @Environment(Library.self) private var library

    var body: some View {
        let endpoints = library.remoteEndpoints
        Section {
            if endpoints.isEmpty {
                Label(
                    library.remoteNetwork.isLoaded
                        ? "No network: join Wi-Fi or Ethernet, or connect Tailscale." : "Looking…",
                    systemImage: "network.slash"
                )
                .foregroundStyle(.secondary)
            }
            ForEach(endpoints, id: \.self) { endpoint in
                LabeledContent {
                    Text(verbatim: endpoint.display).monospaced().textSelection(.enabled)
                } label: {
                    Label(endpoint.kind.title, systemImage: endpoint.kind.symbol)
                }
            }
            tailscaleRow
        } header: {
            HStack {
                Text("Addresses")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { library.remoteNetwork.refresh() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Look at the network again")
            }
        } footer: {
            Text(
                "A device finds this Mac by itself only on the same local network: Bonjour doesn't cross Tailscale. Away from it, connect Tailscale on both, then scan the QR code (it has the Tailscale addresses) or type a Tailscale address. NX Play only reads Tailscale's status: it changes none of its settings and puts nothing on the internet. Requests carry the pairing code over plain HTTP: keep it to networks you trust; over Tailscale it travels inside Tailscale's encryption."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var tailscaleRow: some View {
        let tailscale = library.remoteNetwork.tailscale
        LabeledContent("Tailscale") {
            switch tailscale.state {
            case .running:
                Text(
                    tailscale.dnsName.map { "Connected as \($0)" }
                        ?? "Connected (no MagicDNS name: use the 100.x address)"
                )
                .foregroundStyle(.secondary).textSelection(.enabled)
            case .installed(let state):
                Text("Installed, not connected\(state.map { " (\($0))" } ?? ""): connect it to reach this Mac from your tailnet")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Text("Not installed: not needed on the same network").foregroundStyle(.secondary)
            }
        }
    }
}
