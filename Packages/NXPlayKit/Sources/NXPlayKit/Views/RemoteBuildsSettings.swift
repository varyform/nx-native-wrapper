import SwiftUI

/// Settings › Remote: remote builds between Macs. Allow Remote Builds lets paired Macs build this Mac's games; Pair
/// with Another Mac adds one this Mac builds on, whose library the main window's toolbar then switches to.
struct RemoteBuildsSettings: View {
    @Environment(Library.self) private var library
    @State private var pairing = false

    var body: some View {
        @Bindable var link = library.macLink
        SettingsPage {
            Section {
                Toggle("Allow remote builds", isOn: $link.hostEnabled)
                if link.hostEnabled {
                    LabeledContent("Pairing code") {
                        HStack {
                            Text(link.pairingCode.isEmpty ? "…" : link.pairingCode)
                                .monospaced().textSelection(.enabled)
                            Button("New Code") { link.newPairingCode() }
                        }
                    }
                    if let problem = link.hostProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    ForEach(link.clients) { client in
                        LabeledContent(client.name) {
                            Button("Remove", role: .destructive) { link.removeClient(client) }
                        }
                    }
                }
            } header: {
                Text("This Mac")
            } footer: {
                Footer(
                    "Another Mac on this network running NX Play pairs once with the code, then lists this Mac\u{2019}s games and builds or rebuilds them here, and sees how far each build is. It can\u{2019}t play them, change settings or reach the files. Each code works once."
                )
            }
            Section {
                ForEach(link.hosts) { host in
                    LabeledContent {
                        Button("Unpair", role: .destructive) { link.unpair(host) }
                    } label: {
                        Text(host.name)
                        Text(status(of: host))
                    }
                }
                Button("Pair with Another Mac\u{2026}") { pairing = true }
            } header: {
                Text("Other Macs")
            } footer: {
                Footer(
                    "Build on another Mac: turn on Allow Remote Builds there, then pair with the code it shows. The toolbar switches the main window to its games. A game in a games folder both Macs have shows the other Mac\u{2019}s build here too, and doesn\u{2019}t build on this Mac while that one does."
                )
            }
        }
        .sheet(isPresented: $pairing) { PairMacSheet() }
    }

    private func status(of host: PairedMac) -> String {
        switch library.macLink.connections[host.id] {
        case .connected: "Connected"
        case .connecting: "Connecting\u{2026}"
        case .offline(let reason): reason
        case .searching, nil: "Looking for it\u{2026}"
        }
    }
}

/// Finds NX Play on other Macs of this network and pairs with one, with the code its Settings › Remote shows.
struct PairMacSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var code = ""
    @State private var isPairing = false
    @State private var problem: String?

    var body: some View {
        let macs = library.macLink.discovered
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with Another Mac").font(.headline)
            if macs.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for NX Play on this network\u{2026}").foregroundStyle(.secondary)
                    Text("On the other Mac, turn on Allow Remote Builds in Settings › Remote.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(macs, selection: $selectedID) { mac in
                    Label(mac.name, systemImage: "desktopcomputer").tag(mac.id)
                }
                .frame(height: 120)
                TextField("Pairing code", text: $code, prompt: Text("XXXX-XXXX"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(selectedID == nil)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil || code.isEmpty || isPairing)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { library.macLink.isPairing = true }
        .onDisappear { library.macLink.isPairing = false }
    }

    private func pair() {
        guard let mac = library.macLink.discovered.first(where: { $0.id == selectedID }) else { return }
        isPairing = true
        problem = nil
        Task {
            do {
                try await library.macLink.pair(with: mac, code: code)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            isPairing = false
        }
    }
}
