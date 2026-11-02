import SwiftUI

/// Settings › Devices › iPhone & iPad App: NX Play on an iPhone or iPad lists the games and asks this Mac to install
/// them there (Library+Remote.swift); Install NX Play puts the app itself there (Library+IOSApp.swift).
struct RemoteSettingsSection: View {
    @Environment(Library.self) private var library
    @State private var deviceID = ""

    var body: some View {
        @Bindable var library = library
        Section {
            Toggle("Let iPhones and iPads install games from this Mac", isOn: $library.remoteEnabled)
            if library.remoteEnabled {
                LabeledContent("Address") {
                    Text(verbatim: "\(ProcessInfo.processInfo.hostName):\(RemoteServer.defaultPort)")
                        .textSelection(.enabled)
                }
                LabeledContent("Pairing code") {
                    HStack {
                        Text(library.remoteToken).monospaced().textSelection(.enabled)
                        Button("New Code") { library.renewRemoteToken() }
                    }
                }
                if let problem = library.remoteProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if library.canInstallIOSApp { installRow }
        } header: {
            Text("iPhone & iPad App")
        } footer: {
            Text(
                "NX Play on an iPhone or iPad finds this Mac on the local network, lists the games and asks for one: the Mac builds it, signed with the team above, and installs it over Wi-Fi or the cable. Pair the device with Xcode once, with Connect via network on, and keep the Mac awake. Install NX Play puts the app itself on the device, and renews it before it expires. A new code locks out devices that had the old one."
            )
            .font(.caption).foregroundStyle(.secondary)
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

    /// The first device, until one is chosen.
    private func pickDevice() {
        guard !library.devices.contains(where: { $0.id == deviceID }) else { return }
        deviceID = library.devices.first?.id ?? ""
    }
}
