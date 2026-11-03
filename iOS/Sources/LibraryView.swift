import SwiftUI

/// The Mac's games as tiles: the ones on this device first, ready to play; the rest install from the Mac.
struct LibraryView: View {
    @Environment(Launcher.self) private var launcher
    private static let tile: CGFloat = 170
    private static let spacing: CGFloat = 20

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scroller in
                    ScrollView {
                        ExpiryBanner().padding(.horizontal)
                        if launcher.offline {
                            Label(
                                "\(launcher.mac?.name ?? "The Mac") isn't answering at \(launcher.mac?.endpoint.display ?? "its address"): it may be asleep, NX Play closed, or this \(UIDevice.current.model) on another network. NX Play keeps trying its other addresses; away from home, connect Tailscale.",
                                systemImage: "wifi.exclamationmark"
                            )
                            .foregroundStyle(.orange).padding(.horizontal)
                            // while it's away, Bonjour looks for where the Mac is now (Launcher.unconfirmedAddresses)
                            .onAppear { launcher.finder.start() }
                            .onDisappear { launcher.finder.stop() }
                            if let moved = launcher.unconfirmedAddresses.first {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(
                                        "Something on this network says it's \(launcher.mac?.name ?? "the Mac") at \(moved.display), an address you haven't paired with. NX Play doesn't send the code there by itself: pair again to use it.",
                                        systemImage: "questionmark.circle")
                                    Button("Pair Again with QR Code…", systemImage: "qrcode.viewfinder") {
                                        launcher.showsScanner = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.horizontal)
                            }
                        }
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Self.spacing),
                                count: columns(geometry.size.width)),
                            spacing: 24
                        ) {
                            ForEach(launcher.sortedGames) { game in
                                Button {
                                    launcher.selected = game.id
                                    launcher.sheetGame = game.id
                                } label: {
                                    GameTile(game: game)
                                }
                                .buttonStyle(.plain)
                                .id(game.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: launcher.selected) { _, id in
                        withAnimation { scroller.scrollTo(id) }
                    }
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in
                    launcher.columns = columns(width)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await launcher.refresh(checkingInstalled: true) }
            .toolbar {
                ToolbarItem(placement: .principal) { Header() }
                ToolbarItem(placement: .primaryAction) {
                    Button { launcher.showsSources = true } label: {
                        Label("Sources", systemImage: "arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) { LibraryMenu() }
            }
        }
        .sheet(isPresented: Bindable(launcher).showsSources) { SourcesView() }
        .sheet(
            isPresented: Binding(
                get: { launcher.sheetGame != nil }, set: { if !$0 { launcher.sheetGame = nil } })
        ) {
            if let id = launcher.sheetGame { GameSheet(gameID: id) }
        }
    }

    /// As many tiles as fit the width, so the controller's up and down move by one row.
    private func columns(_ width: CGFloat) -> Int {
        max(2, Int((width - 32 + Self.spacing) / (Self.tile + Self.spacing)))
    }
}

/// NX Play's icon, its name, and the Mac it's connected to.
private struct Header: View {
    @Environment(Launcher.self) private var launcher

    /// The app icon's largest picture for this device (AppIcon60x60 on an iPhone, AppIcon76x76 on an iPad).
    private static let icon: UIImage? = {
        let info = Bundle.main.infoDictionary
        let icons = (info?["CFBundleIcons~ipad"] ?? info?["CFBundleIcons"]) as? [String: Any]
        let files = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        return files?.reversed().lazy.compactMap { UIImage(named: $0) }.first
    }()

    var body: some View {
        let mac = launcher.mac?.name ?? "the Mac"
        let state = launcher.offline ? "\(mac) isn't answering" : "connected to \(mac)"
        // the whole line on an iPad; on an iPhone's narrow bar, the Mac's name alone
        ViewThatFits {
            line(Text("NX Play").font(.headline), Text("(\(state))").foregroundStyle(.secondary))
            line(Text(launcher.offline ? state : mac).font(.headline))
        }
    }

    private func line(_ texts: Text...) -> some View {
        HStack(spacing: 8) {
            if let icon = Self.icon {
                Image(uiImage: icon).resizable().frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            ForEach(texts.indices, id: \.self) { texts[$0].lineLimit(1) }
        }
    }
}

private struct LibraryMenu: View {
    @Environment(Launcher.self) private var launcher

    var body: some View {
        Menu {
            if let device = launcher.device { Text("This \(UIDevice.current.model): \(device.name)") }
            if let team = launcher.info?.team {
                Text("Signed by \(team.name)\(team.free ? " (Personal Team)" : "")")
            }
            if let expires = Expiry.launcher {
                Text("NX Play: \(Expiry.text(expires).lowercased()), \(expires.formatted(date: .abbreviated, time: .omitted))")
            }
            if let mac = launcher.mac { Text("Connected at \(mac.endpoint.display)") }
            Button("Pair Again with QR Code…", systemImage: "qrcode.viewfinder") { launcher.showsScanner = true }
            Button("Choose Another Device") { launcher.forgetDevice() }
            Button("Unpair", role: .destructive) { launcher.unpair() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// Games about to stop opening, and NX Play itself: installing again from the Mac renews them.
private struct ExpiryBanner: View {
    @Environment(Launcher.self) private var launcher

    var body: some View {
        let games = launcher.expiring
        if Expiry.isSoon(Expiry.launcher), let date = Expiry.launcher {
            Label(
                "NX Play itself: \(Expiry.text(date).lowercased()). Reinstall it from the Mac: Settings › Devices › Install NX Play.",
                systemImage: "clock.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !games.isEmpty {
            HStack {
                Label(
                    games.count == 1
                        ? "\(games[0].name): \(Expiry.text(games[0].expires ?? .now).lowercased())."
                        : "\(games.count) games stop opening within two days.",
                    systemImage: "clock.badge.exclamationmark")
                Spacer()
                Button("Renew") { launcher.renewExpiring() }.buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct GameTile: View {
    @Environment(Launcher.self) private var launcher
    let game: RemoteGame

    var body: some View {
        let highlighted = launcher.controller.isConnected && launcher.selected == game.id
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Group {
                    if let image = launcher.icons[game.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(
                                Image(systemName: "gamecontroller").font(.largeTitle)
                                    .foregroundStyle(.secondary))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .opacity(launcher.installedVersion(game) == nil ? 0.55 : 1)
                if let job = game.job, job.isActive {
                    ProgressView(value: job.fraction).padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24).strokeBorder(.tint, lineWidth: 4).padding(-6)
                    .opacity(highlighted ? 1 : 0))
            .scaleEffect(highlighted ? 1.04 : 1)
            .animation(.snappy(duration: 0.15), value: highlighted)
            Text(game.name).font(.headline).lineLimit(1)
            Text(status).font(.caption).lineLimit(1)
                .foregroundStyle(expiring ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .task { await launcher.loadIcon(game) }
    }

    private var expiring: Bool {
        launcher.installedVersion(game) != nil && Expiry.isSoon(game.expires)
    }

    private var status: String {
        if let job = game.job, job.isActive { return job.text }
        if let version = launcher.installedVersion(game) {
            if expiring, let date = game.expires { return Expiry.text(date) }
            return "On this \(UIDevice.current.model) · \(version)"
        }
        if game.job?.status == "failed" { return "Install failed" }
        if launcher.wasRemoved(game) { return "Removed from this \(UIDevice.current.model)" }
        return game.canInstall ? "On the Mac" : "Can't be installed"
    }
}
