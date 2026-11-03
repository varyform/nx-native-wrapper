import Observation
import UIKit

/// A pairing link scanned, pasted or opened, waiting for the player to say yes.
struct PendingPairing: Identifiable {
    let id = UUID()
    let link: PairingLink
}

/// The app's state: the paired Mac, its games, and what's installed here.
@MainActor @Observable
final class Launcher {
    private(set) var mac: PairedMac? {
        didSet { if mac != oldValue { PairingStore.save(mac) } }
    }
    private(set) var info: MacInfo?
    private(set) var games: [RemoteGame] = []
    private(set) var devices: [RemoteDevice] = []
    /// The version installed here, by title ID (uppercased).
    private(set) var installed: [String: String] = [:]
    /// Games this device had and no longer has, deleted from it, by title ID (uppercased): the Mac remembers
    /// what it installed and what it saw.
    private(set) var removed: Set<String> = []
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
    /// Sources: the Mac's repositories, and its downloads into its games folder, for the current pairing only.
    let macSources = MacSources()
    var sources: [RemoteSource] { macSources.sources }
    var downloads: [RemoteDownload] { macSources.downloads }
    var showsSources = false
    let controller = Controller()
    /// The Macs Bonjour finds: pairing lists them, and reconnecting looks for the paired one among them.
    let finder = MacFinder()
    /// A pairing link to confirm (PairingLinkSheet).
    var pendingPairing: PendingPairing?
    /// The QR scanner, open over the library to pair again.
    var showsScanner = false
    private(set) var isPairing = false

    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var iconLoads: Set<String> = []
    @ObservationIgnored private var lastReconnect = Date.distantPast
    @ObservationIgnored private var reconnecting = false
    /// The pairing under way, owned here: Cancel, Unpair and a newer pairing end it, and only the current one may
    /// change the pairing when it's done.
    @ObservationIgnored private var pairing: (id: UInt64, task: Task<Result<PairingAttempt.Success, PairingFailures>, Never>)?
    @ObservationIgnored private var pairingCount: UInt64 = 0
    /// Changes each time the pairing is replaced or removed: an answer asked for under an older one (a reconnect, a
    /// refresh) is dropped instead of written over the new one.
    @ObservationIgnored private var epoch: UInt64 = 0

    init() {
        mac = PairingStore.load()
        controller.onCommand = { [weak self] in self?.handle($0) }
        macSources.client = { [weak self] in self?.mac?.client }
        macSources.onProblem = { [weak self] in self?.problem = $0 }
        macSources.onFinished = { [weak self] in await self?.refresh() }
    }

    /// The pairing is being replaced or removed: answers asked for under the old one are dropped from now on, and
    /// Sources, which showed the old Mac's sources and downloads, closes and forgets them. Called in the same step as
    /// the change, with no wait between.
    private func endPairingEpoch() {
        epoch &+= 1
        macSources.reset()
        showsSources = false
    }

    var device: RemoteDevice? { devices.first { $0.id == mac?.device } }

    // MARK: - Pairing

    /// An opened URL: a pairing link waits for the player's yes (never pairs by itself); any other is ignored.
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == NXPlayPairing.scheme else { return }
        do {
            pendingPairing = PendingPairing(link: try PairingLink.parse(url.absoluteString))
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Pairs from a QR code or link: only with the Mac the link names.
    @discardableResult func pair(with link: PairingLink) async -> Bool {
        await pair(name: link.name, endpoints: link.endpoints, token: link.code, expectedID: link.macID)
    }

    /// Tries the addresses in order and keeps the first where NX Play answers, is the expected Mac (when one is
    /// expected) and takes the code. The code goes only to an address that said it's NX Play (/v1/hello). A failure
    /// leaves the app as it was, a pairing it had included, with what went wrong and what to check. The addresses
    /// given are the ones the player confirmed: the saved code goes only to them later (PairingTrust).
    ///
    /// A newer pairing replaces one under way; Cancel (`cancelPairing`) and Unpair end it. An ended pairing stops its
    /// requests and changes nothing, even if the Mac answers yes afterwards; it returns false.
    @discardableResult func pair(name: String, endpoints: [Endpoint], token: String, expectedID: String?) async -> Bool {
        guard !endpoints.isEmpty else { return false }
        cancelPairing()
        pairingCount &+= 1
        let id = pairingCount
        let token = NXPlayPairing.normalizedCode(token)
        let task = Task {
            await PairingAttempt.run(endpoints: endpoints, token: token, expectedID: expectedID) {
                self.describe($0, at: $1)
            }
        }
        pairing = (id, task)
        isPairing = true
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        // Cancel, Unpair or a newer pairing came first: this one is over
        let current = pairing?.id == id
        if current {
            pairing = nil
            isPairing = false
        }
        guard current, !task.isCancelled else { return false }
        switch result {
        case .success(let success):
            let sameMac = success.macID != nil && success.macID == mac?.macID
            endPairingEpoch()
            info = success.info
            devices = success.devices
            if !sameMac { games = [] }
            mac = PairedMac(
                name: success.info.name, macID: success.macID,
                endpoints: [success.endpoint] + endpoints.filter { $0 != success.endpoint },
                token: token, device: sameMac ? mac?.device : nil)
            offline = false
            problem = nil
            return true
        case .failure(let failures):
            problem = failures.text.isEmpty ? "The Mac didn't answer." : failures.text
            return false
        }
    }

    /// Ends the pairing under way, if any (Cancel on the confirmation sheet): its requests stop, and it changes nothing.
    func cancelPairing() {
        guard let pairing else { return }
        pairing.task.cancel()
        self.pairing = nil
        isPairing = false
    }

    private func describe(_ error: any Error, at endpoint: Endpoint) -> String {
        MacClient.describe(
            error, at: endpoint, localNetworkDenied: finder.status == .denied, device: UIDevice.current.model)
    }

    /// The Mac stopped answering where it was: tries its other confirmed addresses (PairingTrust), checking each is
    /// still the same Mac (/v1/hello) before the code goes there. The one that answers is tried first from then on.
    /// Addresses Bonjour sees it at that the player never confirmed get no code (`unconfirmedAddresses`). At most every
    /// 10 seconds; the pairing is kept either way. A pairing replaced or removed meanwhile ends it, changing nothing.
    func reconnect() async -> Bool {
        guard let paired = mac, !reconnecting, Date().timeIntervalSince(lastReconnect) > 10 else { return false }
        reconnecting = true
        lastReconnect = Date()
        defer { reconnecting = false }
        let epoch = epoch
        for endpoint in PairingTrust.reconnectCandidates(paired) {
            let hello = try? await PairingAttempt.check(endpoint, expectedID: paired.macID)
            guard epoch == self.epoch else { return false }
            guard case .success? = hello else { continue }
            let info = try? await MacClient(endpoint: endpoint, token: paired.token).info()
            guard epoch == self.epoch, let current = mac else { return false }
            // the Mac it answers as is the paired one (an older Mac doesn't say)
            guard let info, info.id == nil || paired.macID == nil || info.id == paired.macID else { continue }
            mac?.endpoints = [endpoint] + current.endpoints.filter { $0 != endpoint }
            return true
        }
        return false
    }

    /// Where Bonjour sees the paired Mac's ID at an address the player never confirmed. The saved code isn't sent
    /// there (anything on the network can claim the ID): the library offers to pair again instead.
    var unconfirmedAddresses: [Endpoint] {
        PairingTrust.unconfirmedAddresses(of: mac, found: finder.found.map { ($0.macID, $0.endpoints) })
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

    /// Forgets the Mac. A pairing under way ends too, so it can't bring the pairing back when it finishes.
    func unpair() {
        cancelPairing()
        stopPolling()
        endPairingEpoch()
        mac = nil
        devices = []
        info = nil
        games = []
        installed = [:]
    }

    func loadDevices() async {
        guard let client = mac?.client else { return }
        let epoch = epoch
        do {
            let list = try await client.devices()
            if epoch == self.epoch { devices = list }
        } catch {
            if epoch == self.epoch { problem = error.localizedDescription }
        }
    }

    // MARK: - Games

    /// While the app is in front: the games every couple of seconds while one builds, else now and then. Starting
    /// (the app coming to the front) asks again what's installed: a game deleted from the home screen meanwhile.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(checkingInstalled: first)
                first = false
                let busy = self.games.contains { $0.job?.isActive == true }
                try? await Task.sleep(for: .seconds(busy ? 2 : 15))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// `checkingInstalled`: ask the device what's installed (devicectl on the Mac, a few seconds), as pull to
    /// refresh does; otherwise only on the first load and after an install. What answers after the pairing was
    /// replaced or removed is dropped.
    func refresh(checkingInstalled: Bool = false) async {
        guard let mac else { return }
        let epoch = epoch
        do {
            if info == nil {
                let answer = try await mac.client.info()
                guard epoch == self.epoch else { return }
                info = answer
            }
            if devices.isEmpty {
                let answer = try await mac.client.devices()
                guard epoch == self.epoch else { return }
                devices = answer
            }
            let answer = try await mac.client.games()
            guard epoch == self.epoch else { return }
            let previous = games
            games = answer
            offline = false
            // an install that just ended changed what's on this device
            let finished = games.contains { game in
                game.job?.kind == "install" && game.job?.isActive == false
                    && previous.first { $0.id == game.id }?.job?.isActive == true
            }
            if checkingInstalled || installed.isEmpty || finished { await loadInstalled() }
        } catch {
            guard epoch == self.epoch else { return }
            offline = true
            // somewhere else it answers: the Mac's other confirmed addresses
            if await reconnect() { await refresh(checkingInstalled: checkingInstalled) }
        }
    }

    private func loadInstalled() async {
        guard let mac, let device = mac.device else { return }
        let epoch = epoch
        guard let list = try? await mac.client.installed(on: device), epoch == self.epoch else { return }
        installed = Dictionary(
            list.apps.map { ($0.titleID.uppercased(), $0.version) }, uniquingKeysWith: { a, _ in a })
        removed = Set(list.removed.map { $0.uppercased() })
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

    /// Deleted from this device since the Mac installed it (or saw it here).
    func wasRemoved(_ game: RemoteGame) -> Bool {
        game.titleID.map { removed.contains($0.uppercased()) } ?? false
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

    // MARK: - Sources

    /// The Mac's sources; `refreshing` reads their catalogs again first. Sources is the current pairing's only
    /// (MacSources): what a screen of an earlier pairing asks, `session`, goes nowhere.
    func loadSources(refreshing: Bool = false) async {
        await macSources.load(refreshing: refreshing)
    }

    /// A source's games; the Mac reads its catalog first when it hasn't yet.
    func entries(of source: RemoteSource, matching words: String, in session: MacSources.Session) async
        -> [RemoteEntry]?
    {
        await macSources.entries(of: source, matching: words, in: session)
    }

    /// The downloads, as the Mac has them. One that just finished brought a game: the library is read again.
    func loadDownloads() async {
        await macSources.loadDownloads()
    }

    func download(_ entry: RemoteEntry, from source: RemoteSource, packages: [String], in session: MacSources.Session)
        async
    {
        await macSources.download(entry, from: source, packages: packages, in: session)
    }

    func cancelDownload(_ job: RemoteDownload, in session: MacSources.Session) async {
        await macSources.cancel(job, in: session)
    }

    func retryDownload(_ job: RemoteDownload, in session: MacSources.Session) async {
        await macSources.retry(job, in: session)
    }

    /// From a finished download to the game's sheet in the library, where Install is: a game of the Mac `session`
    /// belongs to, so nothing happens once the pairing has changed.
    func openInLibrary(_ gameID: String, in session: MacSources.Session) {
        guard session == macSources.session else { return }
        showsSources = false
        selected = gameID
        // one sheet at a time: the game's opens once Sources has gone
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard session == macSources.session else { return }
            sheetGame = gameID
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
