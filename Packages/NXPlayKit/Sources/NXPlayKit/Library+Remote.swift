import Foundation
import SystemConfiguration

/// The iOS app's API (Settings › Devices › iPhone & iPad App). The iPhone or iPad lists the games, picks itself from the devices this
/// Mac reaches, and asks for an install: the Mac builds the game signed with its team and installs it over Wi-Fi
/// with devicectl, as Install on Device does. iOS doesn't let one app install another, so the Mac pushes the app.
/// Every request carries the pairing code (`Authorization: Bearer <code>`).
///
///     GET  /v1/info                      the Mac, NX Play's version, the team
///     GET  /v1/games                     the games, each with its running job
///     GET  /v1/games/<id>/icon           the game's artwork
///     GET  /v1/devices                   the devices an install can go to, looked for again
///     GET  /v1/devices/<udid>/apps       the games installed on a device, and the ones deleted from it
///     POST /v1/games/<id>/install?device=<udid>
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

    /// Where the iOS app reaches the server, as Settings shows it; a sample in screenshot mode.
    public var remoteAddress: String {
        "\(isScreenshot ? "Mac.local" : ProcessInfo.processInfo.hostName):\(RemoteServer.defaultPort)"
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
            return
        }
        guard remoteServer == nil else { return }
        let server = RemoteServer { [weak self] request in
            await self?.respond(to: request) ?? .error(503, "NX Play is quitting")
        }
        server.onProblem = { [weak self] problem in self?.remoteProblem = problem }
        remoteServer = server
        server.start()
    }

    func respond(to request: RemoteRequest) async -> RemoteResponse {
        guard request.bearer == remoteToken else {
            return .error(401, "Wrong pairing code: see NX Play › Settings › Devices on the Mac")
        }
        let route = request.route
        if route("GET", "v1/info") != nil {
            let version: String =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? ""
            // the Mac's name from Sharing settings (Host.current() can wait on DNS)
            let name: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
            var info: [String: Any] = ["name": name, "version": version, "team": NSNull()]
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

    private func remoteJSON(_ game: Game) -> [String: Any] {
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

    private func remoteJSON(_ job: Job) -> [String: Any] {
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

    private func remoteJSON(_ device: Device) -> [String: Any] {
        ["id": device.id, "name": device.name, "model": device.model, "os": device.osVersion]
    }
}
