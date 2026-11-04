import Foundation
import SystemConfiguration

/// The iOS app's API (Settings › Devices › iPhone & iPad App). The iPhone or iPad lists the games, picks itself from the devices this
/// Mac reaches, and asks for an install: the Mac builds the game signed with its team and installs it over Wi-Fi
/// with devicectl, as Install on Device does. iOS doesn't let one app install another, so the Mac pushes the app.
/// Every request carries the pairing code (`Authorization: Bearer <code>`), except `/v1/hello`.
///
///     GET  /v1/hello                     no code needed: {"app": "nxplay", "api": 1, "id": <Mac ID>}, so the app
///                                        checks it reached NX Play on the Mac it expects before it sends the code
///     GET  /v1/info                      the Mac, NX Play's version, the team
///     GET  /v1/games                     the games, each with its running job
///     GET  /v1/games/<id>/icon           the game's artwork
///     GET  /v1/devices                   the devices an install can go to, looked for again
///     GET  /v1/devices/<udid>/apps       the games installed on a device, and the ones deleted from it
///     POST /v1/games/<id>/install?device=<udid>
///     …/v1/sources and /v1/downloads: Sources (Library+Repositories.swift)
///
/// A game's id is its folder's name in the games folder.
extension Library {
    /// A new pairing code: 3 groups of 4 letters and digits, about 60 bits, short enough to type on a phone.
    static func newRemoteToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<3).map { _ in
            String((0..<4).map { _ in alphabet.randomElement()! })
        }.joined(separator: "-")
    }

    /// Where the iOS app reaches the server: the first of `remoteEndpoints` (an address on the local network, before
    /// the .local name), else the host name; a sample in screenshot mode.
    public var remoteAddress: String {
        if let first = remoteEndpoints.first { return first.display }
        return "\(isScreenshot ? "Mac.local" : ProcessInfo.processInfo.hostName):\(remotePort)"
    }

    /// Every address the server is reached at, in the order the iOS app tries them (MacAddresses.endpoints).
    var remoteEndpoints: [Endpoint] { remoteNetwork.endpoints(port: remotePort) }

    /// The link the pairing QR code shows: this Mac's ID and name, the code, and `endpoints` (at most
    /// NXPlayPairing.maxEndpoints of them), made to fit what the iOS app reads (PairingLink.fitting: a long name is
    /// shortened first, then the last addresses are left out). A sample code in screenshot mode, so a screenshot never
    /// shows the real one. Nil without an address.
    func pairingLink(endpoints: [Endpoint]) -> PairingLink? {
        PairingLink.fitting(
            macID: remoteID, name: remoteName, code: isScreenshot ? "abcd-efgh-jkmn" : remoteToken,
            endpoints: endpoints)
    }

    /// The Mac's name from Sharing settings (Host.current() can wait on DNS).
    var remoteName: String {
        if isScreenshot { return "Mac" }
        return SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    }

    /// Settings › Devices' port: the server moves there (restartRemote).
    func setRemotePort(_ value: Int) {
        remotePort = Self.remotePort(value)
    }

    /// Stops the server and starts it again with the current settings: a new port.
    func restartRemote() {
        remoteServer?.stop()
        remoteServer = nil
        applyRemote()
    }

    public func renewRemoteToken() {
        remoteToken = Self.newRemoteToken()
    }

    /// Starts or stops the server to match the setting; never in screenshot mode.
    func applyRemote() {
        guard !isScreenshot, remoteEnabled else {
            remoteServer?.stop()
            remoteServer = nil
            remoteProblem = nil
            remoteAdvertisement = .off
            remoteNetwork.stop()
            return
        }
        remoteNetwork.start()
        guard remoteServer == nil else { return }
        let server = RemoteServer { [weak self] request in
            await self?.respond(to: request) ?? .error(503, "NX Play is quitting")
        }
        server.onProblem = { [weak self] problem in self?.remoteProblem = problem }
        server.onAdvertisement = { [weak self] state in self?.remoteAdvertisement = state }
        remoteServer = server
        server.start(port: remotePort, id: remoteID)
    }

    func respond(to request: RemoteRequest) async -> RemoteResponse {
        // the one answer without the code: that this is NX Play, and which Mac (nothing about the games or devices)
        if request.route("GET", "v1/hello") != nil {
            return .json(["app": NXPlayPairing.helloApp, "api": 1, "id": remoteID])
        }
        guard request.bearer == remoteToken else {
            return .error(401, "Wrong pairing code: see NX Play › Settings › Devices on the Mac")
        }
        let route = request.route
        if route("GET", "v1/info") != nil {
            let version: String =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? ""
            var info: [String: Any] = ["name": remoteName, "version": version, "team": NSNull(), "id": remoteID]
            if let team { info["team"] = ["name": team.name, "free": team.isFree] }
            return .json(info)
        }
        if route("GET", "v1/games") != nil { return .json(games.map(remoteJSON)) }
        if let id = route("GET", "v1/games/*/icon")?.first {
            guard let game = remoteGame(id), let icon = icon(for: game) else {
                return .error(404, "No artwork for \(id)")
            }
            return .file(icon)
        }
        if route("GET", "v1/devices") != nil {
            devices = await Device.load()
            return .json(devices.map(remoteJSON))
        }
        if let udid = route("GET", "v1/devices/*/apps")?.first {
            guard let device = await remoteDevice(udid) else { return .error(404, "No such device") }
            do {
                let apps = try await DeviceCtl.games(on: device)
                let removed = removedGames(on: udid, installed: apps.map(\.titleID))
                // what's there now is remembered too: a game installed before NX Play kept track counts
                remember(apps.map(\.titleID), on: udid)
                return .json([
                    "apps": apps.map {
                        ["bundleID": $0.bundleID, "titleID": $0.titleID, "version": $0.version]
                    },
                    "removed": removed,
                ])
            } catch {
                return .error(502, error.localizedDescription)
            }
        }
        if let id = route("POST", "v1/games/*/install")?.first {
            return await remoteInstall(id, on: request.query["device"] ?? "")
        }
        // Sources: browsing and downloads (Library+Repositories.swift)
        if let response = await respondToRepositories(request) { return response }
        return .error(404, "No such API: \(request.method) /\(request.path.joined(separator: "/"))")
    }

    private func remoteInstall(_ id: String, on udid: String) async -> RemoteResponse {
        guard let game = remoteGame(id) else { return .error(404, "No game \(id)") }
        guard let device = await remoteDevice(udid) else {
            return .error(
                400,
                "The Mac can't reach that device: pair it with Xcode, with Connect via network on")
        }
        guard !isBusy(game) else { return .error(409, "\(game.name) is busy on the Mac") }
        guard !isReserved(game) else { return .error(409, Self.reservedProblem(game)) }
        guard !game.isKept else { return .error(409, Self.keptBuildProblem) }
        guard game.canBuildFromFiles else {
            return .error(422, "\(game.name) has no game files to build from")
        }
        run(.install(device), game, select: false)
        guard let job = job(for: game), job.kind == .install(device) else {
            return .error(500, problem ?? "The install didn't start")
        }
        return .json(remoteJSON(job), status: 202)
    }

    /// A device had these games: installed from this Mac, or listed on it.
    func remember(_ titleIDs: [String], on udid: String) {
        let known = Set(deviceGames[udid] ?? [])
        let all = known.union(titleIDs.map { $0.uppercased() })
        if all != known { deviceGames[udid] = all.sorted() }
    }

    /// The games the device had and no longer lists: deleted there. They stay remembered, so they keep showing as
    /// removed until they're installed again.
    func removedGames(on udid: String, installed: [String]) -> [String] {
        let present = Set(installed.map { $0.uppercased() })
        return (deviceGames[udid] ?? []).filter { !present.contains($0) }
    }

    private func remoteGame(_ id: String) -> Game? {
        games.first { $0.folder.lastPathComponent == id }
    }

    /// A device the Mac reaches, looked for again when the list doesn't have it (it may have woken since).
    private func remoteDevice(_ udid: String) async -> Device? {
        if let device = devices.first(where: { $0.id == udid }) { return device }
        devices = await Device.load()
        return devices.first { $0.id == udid }
    }

    func remoteJSON(_ game: Game) -> [String: Any] {
        [
            "id": game.folder.lastPathComponent,
            "name": game.name,
            "titleID": game.titleID ?? NSNull(),
            "version": game.version ?? NSNull(),
            "state": "\(game.state)",
            "kept": game.isKept,
            "canInstall": game.canBuildFromFiles && !game.isKept,
            "hasIcon": icon(for: game) != nil,
            "job": job(for: game).map(remoteJSON) ?? NSNull(),
            // when the copy installed from this Mac stops opening (a Personal Team's after 7 days)
            "expires": Provisioning.expiration(of: game).map { $0.ISO8601Format() } ?? NSNull(),
        ]
    }

    func remoteJSON(_ job: Job) -> [String: Any] {
        var kind = "\(job.kind)"
        var device: Any = NSNull()
        if case .install(let target) = job.kind {
            kind = "install"
            device = target.id
        }
        var status = "\(job.status)"
        var exitCode: Any = NSNull()
        if case .failed(let code) = job.status {
            status = "failed"
            exitCode = code
        }
        // a failure's reason is in its last lines (xcodebuild's error, devicectl's refusal)
        let reason =
            status == "failed"
            ? job.log.lines.suffix(40).map(\.text).filter { !$0.isEmpty }.suffix(8) : []
        return [
            "kind": kind, "device": device, "status": status, "exitCode": exitCode,
            "fraction": job.progressFraction, "text": job.progressText, "lastLines": Array(reason),
        ]
    }

    func remoteJSON(_ device: Device) -> [String: Any] {
        ["id": device.id, "name": device.name, "model": device.model, "os": device.osVersion]
    }
}
