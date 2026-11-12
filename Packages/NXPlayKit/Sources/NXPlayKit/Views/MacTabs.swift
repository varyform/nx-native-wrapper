import SwiftUI

/// This Mac and each Mac paired to build on, as tabs in the middle of the toolbar (Hive's), once one is paired: the
/// main window shows the chosen one's games. The + menu pairs another and unpairs one: the toolbar takes a right
/// click on its items for its own menu (Icon and Text, Icon Only), so a tab can't have one.
struct MacTabs: View {
    @Environment(Library.self) private var library
    @State private var pairing = false
    @State private var unpairing: PairedMac?

    var body: some View {
        let link = library.macLink
        if !link.hosts.isEmpty {
            HStack(spacing: 2) {
                MacTab(title: "This Mac", status: nil, isActive: link.shownHost == nil) { link.shownHost = nil }
                ForEach(link.hosts) { host in
                    MacTab(
                        title: host.name, status: link.connections[host.id] ?? .searching,
                        isActive: link.shownHost == host.id
                    ) { link.shownHost = host.id }
                }
                Menu {
                    Button("Pair with Another Mac\u{2026}") { pairing = true }
                    Divider()
                    ForEach(link.hosts) { host in
                        Button("Unpair \(host.name)\u{2026}") { unpairing = host }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Pair with another Mac, or unpair one")
                .accessibilityLabel("Pair or unpair a Mac")
            }
            .sheet(isPresented: $pairing) { PairMacSheet() }
            .confirmationDialog(
                "Unpair \(unpairing?.name ?? "")?",
                isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                presenting: unpairing
            ) { host in
                Button("Unpair", role: .destructive) { link.unpair(host) }
            } message: { _ in
                Text("Its builds go on there. Building there again needs a new code from its Settings › Remote.")
            }
        }
    }
}

private struct MacTab: View {
    let title: String
    /// Nil for this Mac.
    let status: MacLink.Connection?
    let isActive: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                if let status {
                    Circle().fill(color(status)).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(isActive ? Color.primary.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(status.map(text) ?? "The games on this Mac")
        .accessibilityLabel(status.map { "\(title), \(text($0))" } ?? title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func color(_ status: MacLink.Connection) -> Color {
        switch status {
        case .connected: .green
        case .connecting, .searching: .orange
        case .offline: .secondary
        }
    }

    private func text(_ status: MacLink.Connection) -> String {
        switch status {
        case .connected: "Connected: build its games from here"
        case .connecting: "Connecting\u{2026}"
        case .searching: "Looking for it on this network\u{2026}"
        case .offline(let reason): reason
        }
    }
}
