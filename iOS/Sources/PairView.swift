import SwiftUI

/// Finds the Macs running NX Play over Bonjour (or takes an address) and pairs with the code NX Play shows in
/// Settings › Devices › iPhone & iPad App.
struct PairView: View {
    @Environment(Launcher.self) private var launcher
    @State private var finder = MacFinder()
    @State private var name = ""
    @State private var host = ""
    @State private var port = "47474"
    @State private var code = ""
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if finder.found.isEmpty {
                        Label("Looking for NX Play on this network…", systemImage: "wifi")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finder.found) { mac in
                        Button {
                            name = mac.name
                            host = mac.host
                            port = String(mac.port)
                        } label: {
                            HStack {
                                Label(mac.name, systemImage: "desktopcomputer")
                                Spacer()
                                if host == mac.host { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text(
                        "On the Mac: NX Play › Settings › Devices › iPhone & iPad App, with \u{201C}Let iPhones and iPads install games from this Mac\u{201D} on."
                    )
                }
                Section("Or by address") {
                    TextField("Mac's address (name.local)", text: $host)
                        .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(
                            .never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                Section {
                    TextField("abcd-efgh-jkmn", text: $code)
                        .font(.body.monospaced())
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Shown under the address in the Mac's Settings.")
                }
                Section {
                    Button {
                        pairing = true
                        Task {
                            await launcher.pair(
                                name: name.isEmpty ? host : name, host: host,
                                port: Int(port) ?? 47_474, token: code)
                            pairing = false
                        }
                    } label: {
                        HStack {
                            Text("Pair")
                            if pairing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(host.isEmpty || code.isEmpty || pairing)
                }
            }
            .navigationTitle("Pair with a Mac")
        }
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
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
