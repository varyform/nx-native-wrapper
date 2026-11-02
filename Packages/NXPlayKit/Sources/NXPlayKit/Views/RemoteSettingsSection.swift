import SwiftUI

/// Settings › Devices › iPad App: lets the iPad app list the games and ask this Mac to install them on the iPad
/// (Library+Remote.swift).
struct RemoteSettingsSection: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Section {
            Toggle("Let the iPad app install games from this Mac", isOn: $library.remoteEnabled)
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
        } header: {
            Text("iPad App")
        } footer: {
            Text(
                "The iPad app finds this Mac on the local network, lists the games and asks for one: the Mac builds it, signed with the team above, and installs it over Wi-Fi. Pair the iPad with Xcode once, with Connect via network on, and keep the Mac awake. A new code locks out iPads that had the old one."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
