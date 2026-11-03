import SwiftUI

@main
struct NXPlayIOSApp: App {
    @State private var launcher = Launcher()

    var body: some Scene {
        WindowGroup {
            RootView().environment(launcher)
        }
    }
}

/// Pair with a Mac, say which of its devices this one is, then the games.
struct RootView: View {
    @Environment(Launcher.self) private var launcher
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var launcher = launcher
        Group {
            if launcher.mac == nil {
                PairView()
            } else if launcher.mac?.device == nil {
                DevicePickerView()
            } else {
                LibraryView()
            }
        }
        // nxplay://pair?… from the camera or a link: confirmed in PairingLinkSheet; anything else is ignored
        .onOpenURL { launcher.open($0) }
        .sheet(isPresented: $launcher.showsScanner) {
            QRScannerSheet { link in
                launcher.showsScanner = false
                // one sheet at a time: the confirmation opens once the scanner has gone
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    launcher.pendingPairing = PendingPairing(link: link)
                }
            }
        }
        .sheet(item: $launcher.pendingPairing) { PairingLinkSheet(pending: $0) }
        .alert(
            "NX Play", isPresented: Binding(get: { launcher.problem != nil }, set: { if !$0 { launcher.problem = nil } })
        ) {
            Button("OK") { launcher.problem = nil }
        } message: {
            Text(launcher.problem ?? "")
        }
        // the Mac is asked only while the app is in front
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active, launcher.mac?.device != nil {
                launcher.startPolling()
            } else if phase != .active {
                launcher.stopPolling()
            }
        }
        .onChange(of: launcher.mac?.device) { _, device in
            if device != nil { launcher.startPolling() }
        }
    }
}
