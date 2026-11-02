import Observation
import UIKit

/// The paired Mac, kept between launches: where it is, its pairing code, and which of its devices this one is.
/// An iPhone or iPad can't learn its own UDID (iOS hides it), so the player picks it once from the Mac's list.
struct PairedMac: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
    var token: String
    var device: String?

    var client: MacClient { MacClient(host: host, port: port, token: token) }
}

/// The app's state: the paired Mac, its games, and what's installed here.
@MainActor @Observable
final class Launcher {
    private(set) var mac: PairedMac? {
        didSet { save() }
    }
    private(set) var info: MacInfo?
    private(set) var games: [RemoteGame] = []
    private(set) var devices: [RemoteDevice] = []
    /// The version installed here, by title ID (uppercased).
    private(set) var installed: [String: String] = [:]
    private(set) var icons: [String: UIImage] = [:]
    var problem: String?
    /// The Mac isn't answering: the games shown are as last seen.
    private(set) var offline = false
    /// The game the controller's highlight is on.
    var selected: RemoteGame.ID?
    /// The game whose sheet is open.
    var sheetGame: RemoteGame.ID?
    /// The grid's columns, as laid out: the controller's up and down move by a row.
    var columns = 4
    let controller = Controller()

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var iconLoads: Set<String> = []
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let macKey = "pairedMac"

    init() {
        mac = defaults.data(forKey: Self.macKey).flatMap {
            try? JSONDecoder().decode(PairedMac.self, from: $0)
        }
        controller.onCommand = { [weak self] in self?.handle($0) }
    }

    private func save() {
        defaults.set(mac.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.macKey)
    }

    var device: RemoteDevice? { devices.first { $0.id == mac?.device } }

    // MARK: - Pairing

    /// Tries the code before keeping it: a wrong one leaves the app where it was, with the Mac's reason.
    func pair(name: String, host: String, port: Int, token: String) async {
        let candidate = PairedMac(
            name: name, host: host, port: port,
            token: token.trimmingCharacters(in: .whitespaces).lowercased())
        do {
            info = try await candidate.client.info()
            devices = try await candidate.client.devices()
            mac = candidate
            if let info { mac?.name = info.name }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func choose(_ device: RemoteDevice) {
        mac?.device = device.id
        installed = [:]
        Task { await refresh() }
    }

    func forgetDevice() {
        mac?.device = nil
        Task { await loadDevices() }
    }

    func unpair() {
        stopPolling()
        mac = nil
        info = nil
        games = []
        installed = [:]
    }

    func loadDevices() async {
        guard let client = mac?.client else { return }
        do {
            devices = try await client.devices()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Games

    /// While the app is in front: the games every couple of seconds while one builds, else now and then.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let busy = self.games.contains { $0.job?.isActive == true }
                try? await Task.sleep(for: .seconds(busy ? 2 : 15))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard let mac else { return }
        do {
            if info == nil { info = try await mac.client.info() }
            if devices.isEmpty { devices = try await mac.client.devices() }
            let previous = games
            games = try await mac.client.games()
            offline = false
            // an install that just ended changed what's on this device
            let finished = games.contains { game in
                game.job?.kind == "install" && game.job?.isActive == false
                    && previous.first { $0.id == game.id }?.job?.isActive == true
            }
            if installed.isEmpty || finished { await loadInstalled() }
        } catch {
            offline = true
        }
    }

    private func loadInstalled() async {
        guard let mac, let device = mac.device else { return }
        guard let apps = try? await mac.client.installed(on: device) else { return }
        installed = Dictionary(
            apps.map { ($0.titleID.uppercased(), $0.version) }, uniquingKeysWith: { a, _ in a })
    }

    /// The grid's order: the games on this device first, ready to play, then the rest by name.
    var sortedGames: [RemoteGame] {
        games.sorted {
            (installedVersion($0) == nil ? 1 : 0, $0.name) < (installedVersion($1) == nil ? 1 : 0, $1.name)
        }
    }

    /// Installed games whose signature runs out within two days (or has): Renew installs them again.
    var expiring: [RemoteGame] {
        games.filter { installedVersion($0) != nil && Expiry.isSoon($0.expires) && $0.job?.isActive != true }
    }

    func renewExpiring() {
        // the Mac queues installs and runs them one at a time
        for game in expiring where game.canInstall { startInstall(game) }
    }

    func installedVersion(_ game: RemoteGame) -> String? {
        game.titleID.flatMap { installed[$0.uppercased()] }
    }

    func install(_ game: RemoteGame) async {
        guard let mac, let device = mac.device else { return }
        do {
            _ = try await mac.client.install(game, on: device)
            await refresh()
            startPolling()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Opens the game by the URL scheme nxplay adds when it installs one (nxplay-<title ID>). A game installed
    /// before that has none: reinstalling adds it.
    func play(_ game: RemoteGame) async {
        guard let id = game.titleID, let url = URL(string: "nxplay-\(id.lowercased())://") else {
            return
        }
        if !(await UIApplication.shared.open(url)) {
            problem =
                "\(game.name) can't be opened from here: reinstall it from the Mac once, then it can."
        }
    }

    /// A tile's artwork, fetched once when it first shows.
    func loadIcon(_ game: RemoteGame) async {
        guard icons[game.id] == nil, game.hasIcon, let client = mac?.client,
            iconLoads.insert(game.id).inserted
        else { return }
        defer { iconLoads.remove(game.id) }
        guard let data = try? await client.icon(game), let image = UIImage(data: data) else { return }
        icons[game.id] =
            await image.byPreparingThumbnail(ofSize: CGSize(width: 512, height: 512)) ?? image
    }
}
