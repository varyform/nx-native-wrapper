import Foundation
import Testing

@testable import NXPlayKit

/// Regressions for the independent review's eight findings, each through the production path it named: concurrent
/// Free Up Space deletions from the API and the window (one library turn, held games, decisions from the disk as it
/// is then), a Retry from the Sources window or the iOS app binding an old job, Install NX Play's end, bulk starts
/// that start nothing, an event cursor at Int.max, a credential in a refused address, coalesced window requests,
/// and parsed booleans. Synthetic folders and defaults only; no nxplay, game, key, device, network or GUI.
@MainActor @Suite(.serialized) final class ControlRecheckTests {
    private var folders: [URL] = []
    private var suites: [String] = []
    private var libraries: [Library] = []

    isolated deinit {
        libraries.forEach { $0.stopControl() }
        suites.forEach(removeTestDefaults)
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: - Fixtures

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-control-recheck/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url.resolvingSymlinksInPath()
    }

    /// A library with the API in process (no listener): calls go through `api.invoke`, the HTTP and MCP routes' own
    /// entry. nxnative and keys point at folders that don't exist, so nothing nxplay could run.
    private func fixture() throws -> (Library, ControlAPI) {
        let base = try folder()
        let suite = testDefaultsName()
        suites.append(suite)
        let library = Library(
            defaults: UserDefaults(suiteName: suite)!, isScreenshot: true,
            artwork: ArtworkStore(directory: base.appending(path: "artwork")))
        library.nxnativePath = base.appending(path: "missing-nxnative").path
        library.keysPath = base.appending(path: "no-keys").path
        let api = ControlAPI(library: library, endpoint: ControlEndpointFile(folder: base.appending(path: "control")))
        library.controlAPI = api
        libraries.append(library)
        return (library, api)
    }

    /// The API listening on loopback for real, for the HTTP route's own parsing.
    private func listening() async throws -> (Library, ControlAPI) {
        let (library, _) = try fixture()
        library.controlAPI = nil
        let api = library.startControl(endpoint: ControlEndpointFile(folder: try folder().appending(path: "control-api")))
        let deadline = Date.now.addingTimeInterval(15)
        while api.port == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(api.port != nil)
        return (library, api)
    }

    private func get(_ api: ControlAPI, _ path: String) async -> ControlTests.Reply {
        let port = api.port ?? 0
        let head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(api.tokenForTests)\r\nContent-Length: 0\r\n\r\n"
        return await ControlTests.send("127.0.0.1", port, Data(head.utf8)) ?? ControlTests.Reply(status: 0, head: "", body: Data())
    }

    /// A games folder with one game of made-up files.
    private func game(_ library: Library, files: [String] = ["Fake.nsp"]) throws -> Game {
        let root = try folder()
        let game = root.appending(path: "Synthetic", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        for file in files { try Data("synthetic \(file)".utf8).write(to: game.appending(path: file)) }
        library.root = root
        return try #require(library.games.first)
    }

    /// A ready game: its game files and a build that plays (a dummy launcher and host, never run).
    private func readyGame(_ library: Library) throws -> (game: Game, original: URL, build: URL, launcher: URL) {
        let initial = try game(library)
        let build = initial.folder.appending(path: "0100000000010000_build", directoryHint: .isDirectory)
        let host = build.appending(path: "tools/dmhost")
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dummy, never executed".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        let launcher = build.appending(path: "start_mac.sh")
        try Data("dummy, never executed".utf8).write(to: launcher)
        library.refresh()
        let ready = try #require(library.games.first)
        try #require(ready.state == .ready)
        return (ready, ready.folder.appending(path: "Fake.nsp"), build, launcher)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// cleanup.delete through `api.invoke`: its status and its answer's JSON text (Sendable, for tasks).
    private func delete(_ api: ControlAPI, _ paths: [URL]) async -> (Int, String) {
        let (status, json) = await api.invoke(
            "cleanup.delete", args: ["paths": paths.map(\.path), "confirm": Cleanup.phrase], waitDone: true, timeout: 10_000)
        return (status, ControlJSON.text(json))
    }

    /// Holds file work on these games until `release` is called: what a long deletion looks like to everyone else.
    private final class Hold {
        var release: CheckedContinuation<Void, Never>?
        var holding = false
    }

    private func hold(_ library: Library, _ games: Set<Game.ID>) async -> (Hold, Task<Void, Never>) {
        let hold = Hold()
        let task = Task { @MainActor in
            await library.fileWork(holding: games) {
                hold.holding = true
                await withCheckedContinuation { hold.release = $0 }
            }
        }
        while hold.release == nil { await Task.yield() }
        return (hold, task)
    }

    // MARK: - 1. Free Up Space: one turn, held games, the disk as it is then

    @Test func twoConcurrentCallsCanNotTakeBothTheGameFilesAndTheOnlyBuild() async throws {
        for order in [false, true] {
            let (library, api) = try fixture()
            let ready = try readyGame(library)
            // both chosen from the same scan, sent at the same time, in either order
            let first = order ? ready.build : ready.original
            let second = order ? ready.original : ready.build
            let a = Task { @MainActor in await self.delete(api, [first]) }
            let b = Task { @MainActor in await self.delete(api, [second]) }
            let ra = await a.value
        let rb = await b.value
            // the first in line deletes what it asked for; the second is refused, having seen the result
            #expect(ra.0 == 200, "first: \(ra.1)")
            #expect(rb.0 == 409, "second: \(rb.1)")
            // a build's folder stays, emptied of the build (its saves are kept): its launcher is what goes
            #expect(!exists(first == ready.build ? ready.launcher : ready.original))
            #expect(exists(second == ready.build ? ready.launcher : ready.original))
            // the game can still play or be built again
            #expect(exists(ready.original) || exists(ready.launcher))
        }
    }

    @Test func theWindowsDeleteAndACallShareTheTurn() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        // CleanupView's Delete calls freeUpSpace with its selection; the API's cleanup.delete calls it too
        let window = Task { @MainActor in await library.freeUpSpace([ready.build]) }
        let call = Task { @MainActor in await self.delete(api, [ready.original]) }
        let windowOutcome = await window.value
        let callReply = await call.value
        guard case .done = windowOutcome else {
            Issue.record("the window's delete, first in line, should have deleted the build: \(windowOutcome)")
            return
        }
        #expect(callReply.0 == 409, "\(callReply.1)")
        #expect(!exists(ready.launcher))
        #expect(exists(ready.original))
        // and the window's Cleanup shows the refusal it gets when it's second
        let cleanup = Cleanup()
        cleanup.finishDeleting(await library.freeUpSpace([ready.original]))
        guard case .failed(let message) = cleanup.phase else {
            Issue.record("expected a refusal, got \(cleanup.phase)")
            return
        }
        #expect(message.hasPrefix("Nothing was deleted"))
        #expect(exists(ready.original))
    }

    @Test func aDeletionIsJudgedByTheDiskNotTheLibrarysLastLook() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        // the game files go behind NX Play's back (Finder, another app): the library hasn't looked again
        try FileManager.default.removeItem(at: ready.original)
        #expect(library.games.first?.hasPackages == true)
        let reply = await delete(api, [ready.build])
        #expect(reply.0 == 409, "\(reply.1)")
        #expect(exists(ready.launcher))  // the only way the game still plays
    }

    @Test func oneCallCanNotTakeAGamesFilesAndItsBuildTogether() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        let reply = await delete(api, [ready.original, ready.build])
        #expect(reply.0 == 409, "\(reply.1)")
        #expect(exists(ready.original) && exists(ready.launcher))
        // the window's own rule says the same of its selection, and the library refuses it too
        let outcome = await library.freeUpSpace([ready.build, ready.original])
        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(exists(ready.original) && exists(ready.launcher))
    }

    @Test func aGameThatBecomesBusyDuringTheFreshScanLosesNothing() async throws {
        let (library, api) = try fixture()
        let game = try game(library)
        let ipa = game.folder.appending(path: "Fake.ipa")
        try Data("synthetic".utf8).write(to: ipa)
        library.refresh()
        let current = try #require(library.games.first)
        let command = try #require(api.command(named: "cleanup.delete"))
        final class Began { var value = false }
        let began = Began()
        let task = Task { @MainActor () -> Int in
            began.value = true
            do throws(ControlError) {
                _ = try await command.run(ControlArgs(values: ["paths": [ipa.path], "confirm": Cleanup.phrase]))
                return 200
            } catch {
                return error.status
            }
        }
        while !began.value { await Task.yield() }
        // a job appears while the command waits on its scan (put in directly: no process is started)
        let run = Job(
            kind: .ipa, game: current,
            command: NXPlayCommand(script: game.folder.appending(path: "never-executed"), arguments: [], environment: [:]))
        library.jobs[current.id] = run
        #expect(await task.value == 409)
        #expect(exists(ipa))
    }

    @Test func nothingStartsOnAGameWhileFileWorkHoldsIt() async throws {
        let (library, api) = try fixture()
        let game = try game(library)
        let (hold, work) = await hold(library, [game.id])
        #expect(library.isReserved(game))
        // a build from the API is refused with the reason, no job, and no alert left for the window
        let (status, json) = await api.invoke("games.extract", args: ["game": "Synthetic"], waitDone: false, timeout: 2000)
        #expect(status == 422)
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
        #expect(message.contains("being deleted"), "\(message)")
        #expect(library.jobs.isEmpty)
        #expect(library.problem == nil)
        // the window's own buttons go through run too: refused, said in the window's alert
        library.extract(game)
        #expect(library.jobs.isEmpty)
        #expect(library.problem == Library.reservedProblem(game))
        library.problem = nil
        // Remove Game waits too; the games' lists for Extract All leave it out
        #expect(!library.canRemove(game))
        #expect(await api.invoke("games.remove", args: ["game": "Synthetic", "confirm": "Synthetic"], waitDone: true, timeout: 2000).0 == 409)
        #expect(library.extractableGames.isEmpty)
        #expect(library.controlActions(game).isEmpty)
        hold.release?.resume()
        await work.value
        #expect(!library.isReserved(game))
        #expect(library.canRemove(game))
    }

    @Test func fileWorkTakesTurnsInOrder() async throws {
        let (library, _) = try fixture()
        let game = try game(library)
        let (hold, first) = await hold(library, [game.id])
        final class Order { var steps: [String] = [] }
        let order = Order()
        let second = Task { @MainActor in
            await library.fileWork(holding: []) { order.steps.append("second") }
        }
        let third = Task { @MainActor in
            await library.fileWork(holding: []) { order.steps.append("third") }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(order.steps.isEmpty)  // waiting for the first
        order.steps.append("first ends")
        hold.release?.resume()
        await first.value
        await second.value
        await third.value
        #expect(order.steps == ["first ends", "second", "third"])
    }

    @Test func removeGameWaitsForADeletionAndJudgesAgain() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        let (hold, work) = await hold(library, [ready.game.id])
        // asked while a deletion holds the game: refused at once rather than racing it
        #expect(await library.remove(ready.game, removingSaves: false) == ["\(ready.game.name) is busy: stop it first."])
        hold.release?.resume()
        await work.value
        // a deletion and a removal at once: one after the other, whichever is first, and nothing is left half done
        let deletion = Task { @MainActor in await self.delete(api, [ready.build]).0 }
        let removal = Task { @MainActor in await library.remove(ready.game, removingSaves: false) }
        let deleted = await deletion.value
        #expect(deleted == 200 || deleted == 404, "\(deleted)")
        #expect(await removal.value.isEmpty)
        #expect(library.games.isEmpty)
    }

    // MARK: - 1b. Keep This Build and a deletion: the keep is refused while the deletion holds the game

    /// cleanup.delete of the build, through the command itself, stopped at its first wait (the fresh scan): the game
    /// is held then, its protection already judged.
    private func deletionWaitingOnItsScan(_ api: ControlAPI, _ library: Library, _ paths: [URL]) async throws -> Task<Int, Never> {
        let command = try #require(api.command(named: "cleanup.delete"))
        final class Began { var value = false }
        let began = Began()
        let task = Task { @MainActor () -> Int in
            began.value = true
            do throws(ControlError) {
                _ = try await command.run(ControlArgs(values: ["paths": paths.map(\.path), "confirm": Cleanup.phrase]))
                return 200
            } catch {
                return error.status
            }
        }
        while !began.value { await Task.yield() }
        return task
    }

    @Test func keepThisBuildIsRefusedWhileADeletionHoldsTheGameFromTheWindowAndTheAPI() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        let keep = try #require(ready.game.keepFile)
        let deletion = try await deletionWaitingOnItsScan(api, library, [ready.build])
        try #require(library.isReserved(ready.game), "the deletion holds the game while it scans")
        // the window's toggle (GameActions calls setKept): refused, said in the window's alert, nothing written
        library.setKept(true, ready.game)
        #expect(library.problem == Library.reservedKeepProblem(ready.game))
        #expect(!exists(keep))
        #expect(library.games.first?.isKept == false)
        library.problem = nil
        // games.set_kept, the API's and MCP's way, through the same setter: a 409 with the reason, no alert left
        let setKept = try #require(api.command(named: "games.set_kept"))
        do throws(ControlError) {
            _ = try await setKept.run(ControlArgs(values: ["game": "Synthetic", "kept": true]))
            Issue.record("games.set_kept should be refused while the build is being deleted")
        } catch {
            #expect(error.status == 409)
            #expect(error.message == Library.reservedKeepProblem(ready.game))
        }
        #expect(library.problem == nil)
        #expect(!exists(keep))
        // the deletion was asked first and goes as asked: the build, and no keep marker said to protect it
        #expect(await deletion.value == 200)
        #expect(!exists(ready.launcher))
        #expect(!exists(keep))
        #expect(exists(ready.original))
        #expect(library.games.first?.isKept == false)
    }

    @Test func keepThisBuildWorksAgainOnceTheHoldEnds() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        let keep = try #require(ready.game.keepFile)
        let (hold, work) = await hold(library, [ready.game.id])
        #expect(await api.invoke("games.set_kept", args: ["game": "Synthetic", "kept": true], waitDone: true, timeout: 2000).0 == 409)
        #expect(!exists(keep))
        hold.release?.resume()
        await work.value
        // no hold: the window's and the API's keep both go through as before
        let (status, json) = await api.invoke("games.set_kept", args: ["game": "Synthetic", "kept": true], waitDone: true, timeout: 2000)
        #expect(status == 200, "\(json)")
        #expect(exists(keep) && library.games.first?.isKept == true)
        library.setKept(false, try #require(library.games.first))
        #expect(!exists(keep) && library.problem == nil)
        library.setKept(true, try #require(library.games.first))
        #expect(exists(keep) && library.problem == nil)
    }

    @Test func aBuildKeptBeforeTheDeletionsTurnStays() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        // queued behind other file work: not held yet, so the keep goes in, and the deletion judges it on its turn
        let (hold, work) = await hold(library, [])
        let deletion = Task { @MainActor in await self.delete(api, [ready.build]) }
        for _ in 0..<20 { await Task.yield() }
        #expect(!library.isReserved(ready.game))
        library.setKept(true, ready.game)
        #expect(library.problem == nil && library.games.first?.isKept == true)
        hold.release?.resume()
        await work.value
        let reply = await deletion.value
        #expect(reply.0 == 409, "\(reply.1)")
        #expect(reply.1.contains("Kept"), "\(reply.1)")
        let keep = try #require(ready.game.keepFile)
        #expect(exists(ready.launcher) && exists(keep))
    }

    @Test func aKeepMarkerWrittenBehindTheLibrarysBackDuringTheScanStopsTheDeletion() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        let keep = try #require(ready.game.keepFile)
        let deletion = try await deletionWaitingOnItsScan(api, library, [ready.build])
        try #require(library.isReserved(ready.game))
        // not through the setter (another app, nxplay's own files): the disk is read again right before deleting
        try Data("Kept by something else".utf8).write(to: keep)
        #expect(await deletion.value == 409)
        #expect(exists(ready.launcher) && exists(keep))
    }

    // MARK: - 2. A Retry from anywhere never rebinds an old job

    private func syntheticDownload(_ library: Library) throws -> DownloadJob {
        let repositories = library.repositories
        let source = RepositorySource(
            id: "synthetic-source", name: "Fake", url: URL(string: "https://example.invalid/catalog.json")!)
        repositories.sources = [source]
        let raw: [String: Any] = [
            "nxplayCatalog": 1,
            "entries": [[
                "id": "fake", "name": "Fake", "titleID": "0100000000010000", "version": "1",
                "packages": [["kind": "base", "filename": "Fake.nsp", "url": "Fake.nsp", "bytes": 1, "sha256": String(repeating: "0", count: 64)]],
            ]],
        ]
        let catalog = try Catalog.parse(JSONSerialization.data(withJSONObject: raw), base: source.url)
        let entry = try #require(catalog.entries.first)
        repositories.states[source.id] = .loaded(catalog, at: .now)
        // no files: a retry has nothing to transfer, so nothing reaches the network
        var download = DownloadJob(id: "same-id", source: source, entry: entry, folder: "Fake", root: try folder(), files: [])
        download.state = .queued
        repositories.downloads = [download]
        return download
    }

    @Test func aRetryFromTheSourcesWindowNeverRebindsTheOldJob() async throws {
        let (library, api) = try fixture()
        let repositories = library.repositories
        let download = try syntheticDownload(library)
        let watcher = ControlWatcher(library: library, hub: api.hub)
        watcher.start()
        defer { watcher.stop() }
        let job = api.hub.newJob(command: "downloads.start", args: [:])
        api.hub.answered(job, .download(download.id, attempt: download.attempt, [:]))
        // the Sources window's Cancel and Retry (DownloadRow), back to back: the watcher doesn't get a turn
        repositories.cancel(download.id)
        let retried = try repositories.retry(download.id)
        #expect(retried.attempt == download.attempt + 1)
        #expect(api.hub.state(job) == .cancelled)
        #expect(repositories.run(download.id, attempt: download.attempt)?.state == .cancelled)
        // cancelling the old job reaches nothing: it has ended, and the new run is someone else's
        #expect(throws: ControlError.self) { try api.hub.cancel(job) }
        #expect(!job.cancelRequested)
        #expect(api.hub.json(job)["state"] as? String == "cancelled")
        // a cancel aimed at the old run never stops the new one: the new run (already the running one, so a cancel
        // would only show once it stops) settles on its own, not cancelled
        repositories.cancel(download.id, attempt: download.attempt)
        let deadline = Date.now.addingTimeInterval(5)
        while repositories.job(download.id)?.state.isActive == true, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let settled = try #require(repositories.job(download.id))
        #expect(!settled.state.isActive)
        #expect(settled.state != .cancelled, "\(settled.state) \(settled.message ?? "")")
        #expect(settled.attempt == retried.attempt)
        // the attempt is kept between launches
        #expect(DownloadJob(record: settled.record)?.attempt == retried.attempt)
    }

    @Test func aRetryFromTheIOSAppToo() async throws {
        let (library, api) = try fixture()
        let download = try syntheticDownload(library)
        let job = api.hub.newJob(command: "downloads.start", args: [:])
        api.hub.answered(job, .download(download.id, attempt: download.attempt, [:]))
        library.repositories.cancel(download.id)
        // the companion's POST /v1/downloads/<id>/retry
        let reply = await library.respondToRepositories(
            RemoteRequest(method: "POST", path: ["v1", "downloads", download.id, "retry"], query: [:], headers: [:]))
        #expect(reply != nil)
        #expect(library.repositories.job(download.id)?.attempt == 2)
        #expect(api.hub.state(job) == .cancelled)
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - 3. Install NX Play's end is seen, and kept

    @Test func anInstallsEndWakesItsJobAndALaterRunCantRewriteIt() async throws {
        let (library, api) = try fixture()
        let device = Device(id: "synthetic", name: "Fake", model: "Fake", osVersion: "0")
        library.startIOSAppInstall(IOSAppInstall(device: device))
        let first = try #require(library.iosAppInstall)
        let watcher = ControlWatcher(library: library, hub: api.hub)
        watcher.start()
        defer { watcher.stop() }
        let job = api.hub.newJob(command: "ios_app.install", args: [:])
        api.hub.answered(job, .iosApp(first.id, [:]))
        let mark = api.hub.lastSeq
        let started = ContinuousClock.now
        let waiter = Task { @MainActor in
            await api.hub.wait(timeout: .seconds(10)) { api.hub.state(job).isFinal }
        }
        library.iosAppInstall?.state = .succeeded
        library.iosAppInstall?.status = "installed"
        await waiter.value
        // woken by the end itself, not by the timeout
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(job.final == .succeeded)
        let names = api.hub.events.filter { $0.seq > mark }.map(\.name)
        #expect(names.contains("ios_app"))
        #expect(names.contains("job"))
        // Settings' button starts another run: the old job stays as its run ended
        library.startIOSAppInstall(IOSAppInstall(device: device))
        api.hub.updateAll()
        #expect(api.hub.state(job) == .succeeded)
    }

    @Test func anInstallReplacedBeforeTheWatcherRunsIsReadAsItEnded() async throws {
        let (library, api) = try fixture()
        let device = Device(id: "synthetic", name: "Fake", model: "Fake", osVersion: "0")
        library.startIOSAppInstall(IOSAppInstall(device: device))
        let first = try #require(library.iosAppInstall)
        let job = api.hub.newJob(command: "ios_app.install", args: [:])
        api.hub.answered(job, .iosApp(first.id, [:]))
        // no watcher at all: it ends and is replaced in one turn
        library.iosAppInstall?.state = .succeeded
        library.startIOSAppInstall(IOSAppInstall(device: device))
        #expect(api.hub.state(job) == .succeeded)
        #expect(library.iosAppInstall(id: first.id)?.state == .succeeded)
        // an id nothing knows is never reported as a success
        let stray = api.hub.newJob(command: "ios_app.install", args: [:])
        api.hub.answered(stray, .iosApp(UUID(), [:]))
        #expect(api.hub.state(stray) == .failed)
    }

    // MARK: - 4. Bulk starts report what started

    @Test func extractAllThatStartsNothingIsAnErrorAndLeavesNoAlert() async throws {
        let (library, api) = try fixture()
        let game = try game(library)
        let (status, json) = await api.invoke("games.extract_all", args: [:], waitDone: true, timeout: 2000)
        #expect(status == 422)
        #expect(json["ok"] as? Bool == false)
        let error = try #require(json["error"] as? [String: Any])
        #expect((error["details"] as? [String: String])?[game.folder.lastPathComponent] != nil)
        #expect(library.jobs.isEmpty)
        #expect(library.problem == nil)
        // nothing to extract at all: refused like the window's disabled button
        try FileManager.default.removeItem(at: game.folder.appending(path: "Fake.nsp"))
        library.refresh()
        #expect(await api.invoke("games.extract_all", args: [:], waitDone: true, timeout: 2000).0 == 409)
    }

    @Test func updateAllThatStartsNothingIsAnErrorAndPutsBackThePowerWait() async throws {
        let (library, api) = try fixture()
        let ready = try readyGame(library)
        #expect(library.updatableGames.map(\.id) == [ready.game.id])
        let (status, json) = await api.invoke(
            "games.update_all", args: ["onlyWhilePluggedIn": true], waitDone: true, timeout: 2000)
        #expect(status == 422, "\(json)")
        #expect(library.jobs.isEmpty)
        #expect(library.problem == nil)
        #expect(!library.buildsWaitForPower)
    }

    @Test func aBulkAnswerListsOnlyWhatStarted() throws {
        let (library, _) = try fixture()
        let game = try game(library)
        let job = Job(
            kind: .extract, game: game,
            command: NXPlayCommand(script: game.folder.appending(path: "never-executed"), arguments: [], environment: [:]))
        let outcome = try library.controlBulkAnswer("extract", started: [job], refused: ["Other": "No nxnative checkout"])
        guard case .value(let value) = outcome, let json = value as? [String: Any] else {
            Issue.record("expected a value")
            return
        }
        #expect(json["queued"] as? [String] == ["Synthetic"])
        #expect(json["refused"] as? [String: String] == ["Other": "No nxnative checkout"])
        #expect(throws: ControlError.self) { try library.controlBulkAnswer("extract", started: [], refused: ["Other": "x"]) }
    }

    // MARK: - 5. Event cursors

    @Test func anEventCursorAtTheEdgesIsAnErrorNotATrap() async throws {
        let (_, api) = try await listening()
        // the hub itself, at the values that trapped: answers, doesn't crash
        for after in [Int.max, Int.max - 1, Int.min, -1] {
            let answer = api.hub.events(after: after, names: nil, limit: 1)
            #expect(answer["missed"] as? Bool != nil)
        }
        for bad in ["9223372036854775807", "9223372036854775808", "-1", "2147483648", "abc", "1.5", ""] {
            let reply = await get(api, "/v1/events?after=\(bad)")
            #expect(reply.status == 400, "after=\(bad): \(reply.status)")
            #expect(reply.errorCode == "invalid_args")
        }
        for bad in ["limit=0", "limit=1001", "wait_ms=-5", "wait_ms=99999999999999999999"] {
            #expect(await get(api, "/v1/events?\(bad)").status == 400, "\(bad)")
        }
        #expect(await get(api, "/v1/jobs/job-1?wait_ms=-1").status == 400)
        // the edges that are fine
        let top = await get(api, "/v1/events?after=2147483647&limit=1")
        #expect(top.status == 200)
        #expect((top.result as? [String: Any])?["missed"] as? Bool == false)
        let zero = await get(api, "/v1/events?after=0&limit=1000")
        #expect(zero.status == 200)
        #expect(await get(api, "/v1/status").status == 200)  // and the app is still there
    }

    @Test func missedIsSaidOnlyWhenEventsWereDropped() throws {
        let (_, api) = try fixture()
        for index in 0..<(ControlHub.keptEvents + 5) { api.hub.emit("test", ["n": index]) }
        let oldest = try #require(api.hub.events.first?.seq)
        #expect(api.hub.events(after: 0, names: nil, limit: 1)["missed"] as? Bool == true)
        #expect(api.hub.events(after: oldest - 2, names: nil, limit: 1)["missed"] as? Bool == true)
        #expect(api.hub.events(after: oldest - 1, names: nil, limit: 1)["missed"] as? Bool == false)
        #expect(api.hub.events(after: api.hub.lastSeq, names: nil, limit: 1)["missed"] as? Bool == false)
    }

    // MARK: - 6. A credential in an address isn't kept

    @Test func aRefusedAddressKeepsNoCredentialAnywhere() async throws {
        let (library, api) = try fixture()
        let watcher = ControlWatcher(library: library, hub: api.hub)
        watcher.start()
        defer { watcher.stop() }
        let secret = "SYNTHETIC-SECRET-DO-NOT-USE"
        let addresses = [
            "https://user:\(secret)@example.invalid/catalog.json?token=\(secret)",
            "https://example.invalid/catalog.json?page=1&api_key=\(secret)",
            "https://example.invalid/catalog.json?X-Amz-Signature=\(secret)",
            "not an address :// \(secret)@x?token=\(secret)",
        ]
        for address in addresses {
            let (status, json) = await api.invoke("sources.add", args: ["url": address], waitDone: true, timeout: 2000)
            #expect(status >= 400, "\(address)")
            let id = try #require(json["job_id"] as? String)
            let job = try #require(api.hub.job(id))
            for text in [ControlJSON.text(api.hub.json(job)), ControlJSON.text(json), ControlJSON.text(api.hub.json(job, full: false))] {
                #expect(!text.contains(secret), "\(text)")
            }
        }
        let events = ControlJSON.text(api.hub.events(after: 0, names: nil, limit: 1000))
        #expect(!events.contains(secret))
        #expect(library.repositories.sources.isEmpty)
        // MCP's way in keeps none either
        let reply = await ControlMCP(api: api).respond(
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "nx_sources_add", "arguments": ["url": addresses[0]]],
            ]), headers: [:])
        #expect(!String(decoding: reply.body, as: UTF8.self).contains(secret))
        for job in api.hub.jobs { #expect(!ControlJSON.text(api.hub.json(job)).contains(secret)) }
    }

    @Test func addressesAreScrubbedAndOrdinaryTextIsNot() {
        let scrubbed = ControlRedaction.scrub(
            "Can't add “https://me:pw@host.example/c.json?page=2&token=t0k#access_token=z9”, try again")
        #expect(!scrubbed.contains("pw") && !scrubbed.contains("t0k") && !scrubbed.contains("z9"))
        #expect(scrubbed.contains("host.example/c.json") && scrubbed.contains("page=2"))
        #expect(scrubbed.hasPrefix("Can't add “") && scrubbed.hasSuffix("”, try again"))
        #expect(ControlRedaction.scrub("Fake Game 2: no :// here") == "Fake Game 2: no :// here")
        #expect(ControlRedaction.scrub("https://host.example/catalog.json") == "https://host.example/catalog.json")
        #expect(!ControlRedaction.scrub("typed :// me:hunter2@host").contains("hunter2"))
        let args = ControlRedaction.redact(["url": "https://u:p@h.example/x", "name": "plain", "list": ["https://h.example/?sig=s"]])
        #expect(!ControlJSON.text(args).contains(":p@") && !ControlJSON.text(args).contains("sig=s"))
        #expect((args as? [String: Any])?["name"] as? String == "plain")
    }

    /// The review's recheck: credential names written percent-encoded, once or more, a name carrying a whole
    /// `name=value`, a fully encoded address and a redirect's, refused by sources.add, keep their secret nowhere: the
    /// full and short job, the answer, the error, the events, the HTTP job and events through the real loopback
    /// listener, and MCP's tools/call and nxapi_job.
    @Test func anEncodedCredentialNameKeepsNoCredentialAnywhere() async throws {
        let (library, api) = try await listening()
        let watcher = ControlWatcher(library: library, hub: api.hub)
        watcher.start()
        defer { watcher.stop() }
        let cases: [(name: String, address: (String) -> String)] = [
            ("encoded-token", { "https://example.invalid/catalog.json?%74oken=\($0)" }),
            ("encoded-api-key", { "https://example.invalid/catalog.json?%61pi_%6bey=\($0)" }),
            ("encoded-amz", { "https://example.invalid/catalog.json?page=1&%58-%41mz-%53ignature=\($0)" }),
            // decoded twice: plain http off the local network is refused, so nothing is added or fetched
            ("double-encoded", { "http://example.invalid/catalog.json?%2574oken=\($0)" }),
            // the refusal quotes the decoded name, `token=…`, without any address around it
            ("name-carries-value", { "https://example.invalid/catalog.json?token%3D\($0)" }),
            ("encoded-equals-and-name", { "https://example.invalid/catalog.json?%74oken%3D\($0)" }),
            // the refusal quotes the whole thing back: “…” isn't an address
            ("fully-encoded", { "https%3A%2F%2Fexample.invalid%2Fcatalog.json%3Ftoken%3D\($0)" }),
            ("redirect", { "http://example.invalid/catalog.json?next=https%3A%2F%2Fauth.invalid%2F%3Faccess_token%3D\($0)" }),
            ("encoded-fragment", { "http://example.invalid/catalog.json#access_token%3D\($0)" }),
            // a malformed escape elsewhere used to hide every name from the check, and the address was added
            ("malformed-escape", { "https://example.invalid/catalog.json?%74oken=\($0)&x=%zz" }),
        ]
        var secrets: [String] = []
        var jobIDs: [String] = []
        for (name, address) in cases {
            let secret = "SYNTHETIC-\(name.uppercased())-DO-NOT-USE"
            secrets.append(secret)
            let (status, json) = await api.invoke("sources.add", args: ["url": address(secret)], waitDone: true, timeout: 2000)
            #expect(status >= 400, "\(name): \(json)")
            let id = try #require(json["job_id"] as? String)
            jobIDs.append(id)
            let job = try #require(api.hub.job(id))
            for text in [ControlJSON.text(api.hub.json(job)), ControlJSON.text(json), ControlJSON.text(api.hub.json(job, full: false))] {
                #expect(!text.contains(secret), "\(name): \(text)")
            }
            // the error still says why
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
            #expect(!message.isEmpty, "\(name)")
        }
        #expect(library.repositories.sources.isEmpty)
        // MCP's way in: tools/call, then nxapi_job and nxapi_events for what it kept
        let mcp = ControlMCP(api: api)
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> String {
            let reply = await mcp.respond(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
                ]), headers: [:])
            return String(decoding: reply.body, as: UTF8.self)
        }
        for (index, (_, address)) in cases.enumerated() {
            let text = try await call("nx_sources_add", ["url": address(secrets[index])])
            #expect(!text.contains(secrets[index]), "\(text)")
        }
        for id in api.hub.jobs.map(\.id) {
            let text = try await call("nxapi_job", ["job": id])
            #expect(!secrets.contains { text.contains($0) }, "\(text)")
        }
        let mcpEvents = try await call("nxapi_events", ["after": 0, "limit": 1000])
        #expect(!secrets.contains { mcpEvents.contains($0) })
        // the HTTP routes, through the loopback listener with its token
        for id in jobIDs {
            let reply = await get(api, "/v1/jobs/\(id)")
            #expect(reply.status == 200)
            let text = String(decoding: reply.body, as: UTF8.self)
            #expect(!secrets.contains { text.contains($0) }, "\(text)")
        }
        let jobs = await get(api, "/v1/jobs")
        #expect(jobs.status == 200 && !secrets.contains { String(decoding: jobs.body, as: UTF8.self).contains($0) })
        let events = await get(api, "/v1/events?after=0&limit=1000")
        #expect(events.status == 200 && !secrets.contains { String(decoding: events.body, as: UTF8.self).contains($0) })
        #expect(!secrets.contains { ControlJSON.text(api.hub.events(after: 0, names: nil, limit: 1000)).contains($0) })
    }

    @Test func encodedNamesAreJudgedDecodedAndTheAddressKeepsItsEncoding() {
        let secret = "S3CR3T-VALUE"
        // the encoding of what stays is kept: only the value goes
        #expect(ControlRedaction.scrub("https://h.example/c.json?%74oken=\(secret)&page=2") == "https://h.example/c.json?%74oken=***&page=2")
        #expect(ControlRedaction.scrub("https://h.example/c.json?%2574oken=\(secret)") == "https://h.example/c.json?%2574oken=***")
        #expect(ControlRedaction.scrub("https://h.example/c.json?%61pi_%6bey=\(secret)") == "https://h.example/c.json?%61pi_%6bey=***")
        // a name that carries the value itself goes as its decoded name
        #expect(ControlRedaction.scrub("https://h.example/c.json?token%3D\(secret)") == "https://h.example/c.json?token=***")
        #expect(!ControlRedaction.scrub("https://h.example/c.json?%74oken%253D\(secret)").contains(secret))
        // free text that isn't a parsable address, and a malformed escape anywhere, still lose the value
        #expect(!ControlRedaction.scrub("typed :// h?%74oken=\(secret) and %zz").contains(secret))
        #expect(!ControlRedaction.scrub("typed :// h?to%6Ben%3D\(secret)").contains(secret))
        #expect(!ControlRedaction.scrub("https://h.example/c.json?%74oken=\(secret)&bad=%zz").contains(secret))
        // a redirect's address and an encoded fragment
        #expect(!ControlRedaction.scrub("https://h.example/?next=https%3A%2F%2Fa.example%2F%3Fsig%3D\(secret)").contains(secret))
        #expect(!ControlRedaction.scrub("https://h.example/#access_token%3D\(secret)").contains(secret))
        // a fragment with an "=" goes whatever its name (OAuth's implicit flow), its "=" encoded or not
        #expect(ControlRedaction.scrub("https://h.example/#x=\(secret)") == "https://h.example/#***")
        #expect(ControlRedaction.scrub("https://h.example/#x%3D\(secret)") == "https://h.example/#***")
        // fully encoded: judged and shown decoded
        #expect(ControlRedaction.scrub("https%3A%2F%2Fh.example%2F%3Ftoken%3D\(secret)") == "https://h.example/?token=***")
        // a name encoded over and over is read to the end: a secret one counts as one, an ordinary one doesn't
        var deep = "token"
        var ordinary = "page"
        for _ in 0..<30 {
            deep = deep.addingPercentEncoding(withAllowedCharacters: .alphanumerics.subtracting(.letters))!
            ordinary = ordinary.addingPercentEncoding(withAllowedCharacters: .alphanumerics.subtracting(.letters))!
        }
        #expect(ControlRedaction.isSecretQueryName(deep) && !ControlRedaction.isSecretQueryName(ordinary))
        #expect(!ControlRedaction.scrub("https://h.example/?\(deep)=\(secret)").contains(secret))
        #expect(ControlRedaction.scrub("https://h.example/?\(ordinary)=2") == "https://h.example/?\(ordinary)=2")
        // negative controls: ordinary names and text, encoded or not, malformed or not, stay exactly as they were
        for text in [
            "https://h.example/c.json?%70age=2&q=a%2Fb", "https://h.example/c.json?q=100%25&sort=%2525",
            "50% done, 100%25 sure", "Fake Game: no :// here?name=%74oken",
            "https%3A%2F%2Fh.example%2Fc.json%3Fpage%3D2", "https://h.example/?next=https%3A%2F%2Fa.example%2F%3Fpage%3D2",
        ] {
            #expect(ControlRedaction.scrub(text) == text, "\(text)")
        }
        #expect(!ControlRedaction.isSecretQueryName("%70age") && ControlRedaction.isSecretQueryName("%74oken"))
        #expect(ControlRedaction.lenientlyDecoded("a%zz%7%41%") == "a%zz%7A%")
        // scrubbing twice changes nothing more
        let once = ControlRedaction.scrub("https://u:p@h.example/c.json?%74oken=\(secret)&token%3D\(secret)#a%3D1")
        #expect(ControlRedaction.scrub(once) == once && !once.contains(secret))
    }

    @Test func theSourcesCheckReadsNamesAsWrittenAndQuotesNoValue() throws {
        func problem(_ address: String) throws -> String? {
            RepositoryAddress.secretQueryProblem(try #require(URL(string: address)))
        }
        for address in [
            "https://h.example/c.json?%74oken=S3CR3T", "https://h.example/c.json?%74oken=S3CR3T&x=%zz",
            "https://h.example/c.json?%2574oken=S3CR3T", "https://h.example/c.json?page=1&%58-%41mz-%53ignature=S3CR3T",
            "https://h.example/c.json?token%3DS3CR3T",
        ] {
            let message = try #require(try problem(address), "\(address)")
            #expect(!message.contains("S3CR3T"), "\(message)")
        }
        #expect(try problem("https://h.example/c.json?token%3DS3CR3T")?.contains("“token”") == true)
        // negative controls: ordinary names stay accepted, malformed or encoded
        for address in [
            "https://h.example/c.json", "https://h.example/c.json?page=2&q=%zz", "https://h.example/c.json?%70age=2",
            "https://h.example/c.json?q=a%3Dtoken",
        ] {
            #expect(try problem(address) == nil, "\(address)")
        }
    }

    @Test func whatAnArgumentHidLeavesTheWholeJob() {
        let secret = "S3CR3T-NAME-VALUE"
        let job = ControlJob(
            id: "job-test", command: "sources.add",
            args: ["url": "https://h.example/c.json?token%3D\(secret)", "name": "my \(secret) source"])
        #expect(!ControlJSON.text(job.args).contains(secret))
        // the backend's refusal quotes the decoded name, with no address around it
        #expect(job.cleanText("the address has “token=\(secret)” in it") == "the address has “***” in it")
        #expect(!ControlJSON.text(job.clean(["message": "token=\(secret)", "list": [secret]])).contains(secret))
        // negative control: a job whose arguments hid nothing changes no ordinary text
        let plain = ControlJob(id: "job-plain", command: "games.list", args: ["filter": "Fake"])
        #expect(plain.cleanText("Fake Game token=none 50%") == "Fake Game token=none 50%")
        #expect(plain.removed.values.isEmpty)
    }

    // MARK: - 6b. Recheck 2: every event is scrubbed where it is kept, and encodings are read to the end

    /// `https://example.invalid/catalog.json?token=<secret>` written fully encoded, `layers` times over.
    private func fullyEncoded(_ secret: String, layers: Int) -> String {
        var address = "https%3A%2F%2Fexample.invalid%2Fcatalog.json%3Ftoken%3D\(secret)"
        for _ in 1..<layers { address = address.replacingOccurrences(of: "%", with: "%25") }
        return address
    }

    /// The same address with only its ":" escaped (`https%3A//…?token=<secret>`), `layers` times over: the most layers
    /// that fit in an argument, each costing a whole reading.
    private func singlyEncoded(_ secret: String, layers: Int) -> String {
        var address = "https%3A//example.invalid/catalog.json?token=\(secret)"
        for _ in 1..<layers { address = address.replacingOccurrences(of: "%", with: "%25") }
        return address
    }

    private func mcpCall(_ api: ControlAPI, _ tool: String, _ arguments: [String: Any]) async throws -> String {
        let reply = await ControlMCP(api: api).respond(
            try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
            ]), headers: [:])
        return String(decoding: reply.body, as: UTF8.self)
    }

    /// Every place the API keeps or shows jobs and events, as text: the hub's own log, `api.events`, every job in
    /// full and short, HTTP `/v1/events`, `/v1/jobs` and each `/v1/jobs/<id>` through the real loopback listener with
    /// its token, and MCP's nxapi_events and nxapi_job for each job.
    private func everywhere(_ api: ControlAPI) async throws -> [(place: String, text: String)] {
        var texts: [(place: String, text: String)] = [
            ("hub events", ControlJSON.text(api.hub.events.map { ["name": $0.name, "data": $0.data] as [String: Any] })),
            ("api.events", ControlJSON.text(await api.events(after: 0, names: nil, limit: 1000, waitMS: 0))),
            ("MCP nxapi_events", try await mcpCall(api, "nxapi_events", ["after": 0, "limit": 1000])),
        ]
        for path in ["/v1/events?after=0&limit=1000", "/v1/jobs"] + api.hub.jobs.map({ "/v1/jobs/\($0.id)" }) {
            let reply = await get(api, path)
            #expect(reply.status == 200, "\(path)")
            texts.append(("HTTP \(path)", String(decoding: reply.body, as: UTF8.self)))
        }
        for job in api.hub.jobs {
            texts.append(("job \(job.id)", ControlJSON.text(api.hub.json(job))))
            texts.append(("short job \(job.id)", ControlJSON.text(api.hub.json(job, full: false))))
            texts.append(("MCP nxapi_job \(job.id)", try await mcpCall(api, "nxapi_job", ["job": job.id])))
        }
        return texts
    }

    /// The newest event called `name` after `seq` that `match` accepts, waiting for the watcher to see the change.
    private func event(
        _ api: ControlAPI, _ name: String, after seq: Int, _ match: ([String: Any]) -> Bool = { _ in true }
    ) async throws -> [String: Any] {
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if let found = api.hub.events.last(where: { $0.seq > seq && $0.name == name && match($0.data) }) {
                return found.data
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(nil as [String: Any]?, "no \(name) event after \(seq)")
    }

    /// The review's R3, through production: a call's job hid the credential, and the watcher's own events about the
    /// same change (a search, a download's message, an install's status) kept it. Each producer's event is now kept
    /// scrubbed, with what isn't secret as it was, and no way in shows the secret.
    @Test func aWatchedChangeWithACredentialKeepsItInNoEvent() async throws {
        let (library, api) = try await listening()
        var secrets: [String] = []
        let searches: [(name: String, text: (String) -> String, shown: String)] = [
            ("NAME", { "https://example.invalid/catalog.json?%74oken=\($0)" }, "https://example.invalid/catalog.json?%74oken=***"),
            ("NINE", { self.fullyEncoded($0, layers: 9) }, "https://example.invalid/catalog.json?token=***"),
            ("USER", { "https://me:\($0)@example.invalid/c.json" }, "https://***@example.invalid/c.json"),
            ("NEXT", { "https://example.invalid/?next=https%3A%2F%2Fa.invalid%2F%3Fsig%3D\($0)" }, "https://example.invalid/?next=***"),
        ]
        for (name, text, shown) in searches {
            let secret = "SYNTH-W-\(name)-X"
            secrets.append(secret)
            let seq = api.hub.lastSeq
            let (status, json) = await api.invoke("ui.search", args: ["text": text(secret)], waitDone: true, timeout: 2000)
            #expect(status == 200, "\(name): \(json)")
            #expect(library.search == text(secret))
            let ui = try await event(api, "ui", after: seq) { $0["search"] != nil }
            #expect(ui["search"] as? String == shown, "\(name): \(ui)")
        }
        // a download's message (a transfer quoting its signed address)
        let downloadSecret = "SYNTH-W-DOWNLOAD-X"
        secrets.append(downloadSecret)
        _ = try syntheticDownload(library)
        var seq = api.hub.lastSeq
        library.repositories.downloads[0].message =
            "Couldn't get https://example.invalid/Fake.nsp?X-Amz-Signature=\(downloadSecret) (try again)"
        let download = try await event(api, "download", after: seq) { ($0["message"] as? String)?.contains("Couldn't get") == true }
        #expect(download["message"] as? String == "Couldn't get https://example.invalid/Fake.nsp?X-Amz-Signature=*** (try again)")
        // Install NX Play's status
        let installSecret = "SYNTH-W-INSTALL-X"
        secrets.append(installSecret)
        seq = api.hub.lastSeq
        var install = IOSAppInstall(device: Device(id: "synthetic", name: "Fake", model: "Fake", osVersion: "0"))
        install.status = "Fetching https://example.invalid/app.ipa?%74oken=\(installSecret)"
        library.startIOSAppInstall(install)
        let ios = try await event(api, "ios_app", after: seq)
        #expect(ios["status"] as? String == "Fetching https://example.invalid/app.ipa?%74oken=***")
        for (place, text) in try await everywhere(api) {
            for secret in secrets { #expect(!text.contains(secret), "\(place) shows \(secret)") }
        }
    }

    /// The shared boundary itself: whatever a producer hands `emit` (a build's text too) is kept scrubbed, a job's
    /// event also loses what its job hid, and ordinary values are kept exactly. Negative controls: an event with
    /// nothing secret is unchanged (numbers, booleans, nulls, lists, `%` and paths included); the hub's own words for
    /// a job stay even when they equal something it hid; another job's hidden values don't touch an unrelated event.
    @Test func everyEventIsScrubbedWhereItIsKeptAndOrdinaryValuesAreNot() throws {
        let (_, api) = try fixture()
        let hub = api.hub
        let secret = "SYNTH-EMIT-SECRET"
        hub.emit("build", ["game": "Fake", "text": "Fetching https://example.invalid/x?sig=\(secret) · 40%", "fraction": 0.4])
        #expect(hub.events.last?.data["text"] as? String == "Fetching https://example.invalid/x?sig=*** · 40%")
        // a job whose argument hid a value (under a secret-looking key) that another job's text later quotes bare
        let job = hub.newJob(command: "sources.add", args: ["url": "https://example.invalid/c.json", "token": secret])
        hub.emit("job", ["job": job.id, "command": job.command, "state": "running", "note": "quoting \(secret)"], for: job)
        let kept = try #require(hub.events.last?.data)
        #expect(kept["note"] as? String == "quoting ***" && kept["job"] as? String == job.id)
        // negative control: the hub's words stay, even equal to what the job hid
        let words = hub.newJob(command: "ui.search", args: ["token": "running", "text": "Synthetic"])
        hub.emit("job", ["job": words.id, "command": words.command, "state": "running"], for: words)
        let state = try #require(hub.events.last?.data)
        #expect(state["state"] as? String == "running" && state["command"] as? String == "ui.search")
        // negative control: an event about no job is never touched by any job's hidden values ("running" above)
        let ordinary: [String: Any] = [
            "gamesFolder": "/tmp/Games 50%/Fake %41", "games": 3, "added": ["Synthetic", "running"], "removed": [String](),
            "changed": ["Fake"], "flag": true, "none": NSNull(), "fraction": 0.25, "text": "50% done, 100%25 sure",
            "address": "https://example.invalid/catalog.json?page=2&q=a%2Fb", "status": "running",
        ]
        hub.emit("library", ordinary)
        #expect(ControlJSON.text(hub.events.last?.data as Any) == ControlJSON.text(ordinary))
        #expect(hub.events.last?.data["games"] as? Int == 3 && hub.events.last?.data["flag"] as? Bool == true)
        // what's kept is a copy: the job can go (trimmed) and its events stay as they were kept
        #expect(!ControlJSON.text(hub.events.map(\.data)).contains(secret))
    }

    /// The review's R1b: a fully encoded address one layer past the old fixed bound was kept whole in the refused
    /// job. Now every encoding is read to the end within a budget for the field (8, 9, 40 and 160 layers come out
    /// decoded and scrubbed), and one too costly to read (≈980 layers, still within sources.add's 2048 characters) is
    /// hidden whole, in the job, its error, its events, HTTP and MCP. Nothing is added either way.
    @Test func aFullyEncodedAddressIsReadToTheEndOrHiddenWhole() async throws {
        let (library, api) = try await listening()
        var secrets: [String] = []
        for layers in [8, 9, 40, 160, 980] {
            let secret = "SYNTHETIC-DEEP-\(layers)-SECRET"
            secrets.append(secret)
            let exhausted = layers == 980
            let address = exhausted ? singlyEncoded(secret, layers: layers) : fullyEncoded(secret, layers: layers)
            #expect(address.count <= 2048)
            #expect(ControlRedaction.exhausts(address) == exhausted, "\(layers)")
            #expect(ControlRedaction.scrub(address) == (exhausted ? "***" : "https://example.invalid/catalog.json?token=***"))
            let (status, json) = await api.invoke("sources.add", args: ["url": address], waitDone: true, timeout: 5000)
            #expect(status == 422, "\(layers): \(json)")
            let id = try #require(json["job_id"] as? String)
            let job = try #require(api.hub.job(id))
            let args = try #require(job.args as? [String: Any])
            #expect(args["url"] as? String == (exhausted ? "***" : "https://example.invalid/catalog.json?token=***"))
            #expect(!ControlJSON.text(json).contains(secret))
            #expect(!(try await mcpCall(api, "nx_sources_add", ["url": address])).contains(secret))
        }
        #expect(library.repositories.sources.isEmpty)
        for (place, text) in try await everywhere(api) {
            for secret in secrets { #expect(!text.contains(secret), "\(place) shows \(secret)") }
        }
    }

    /// Bounded cost, fail closed, and no harm to ordinary text: a field's reading costs at most its budget however
    /// it is built (deep encodings, a chain of values nested in values), what can't be read within it is hidden whole
    /// and remembered for the job, and ordinary text, deeply encoded or large, comes back exactly as it was.
    @Test func readingIsBoundedFailsClosedAndLeavesOrdinaryTextAlone() {
        let secret = "SYNTHETIC-BOUND-SECRET"
        let clock = ContinuousClock()
        // far too deep for any budget: hidden whole and remembered, quickly
        var deep = "https%3A%2F%2Fexample.invalid%2F%3Ftoken%3D\(secret)"
        for _ in 0..<2000 { deep = deep.replacingOccurrences(of: "%", with: "%25") }
        let removed = ControlRedaction.Removed()
        var started = clock.now
        #expect(ControlRedaction.scrub(deep, removed: removed) == "***")
        #expect(clock.now - started < .seconds(10))
        #expect(removed.hide("quoted: \(deep)") == "quoted: ***")
        #expect(ControlRedaction.decodedLayers(deep) == nil && ControlRedaction.isSecretQueryName(deep))
        // the same address inside an address, and as a value's redirect: the field goes whole
        #expect(ControlRedaction.scrub("see https://h.example/?next=\(deep)") == "***")
        // values nested in values, each one more layer down: work that would grow with every layer it explores
        var chain = "token=\(secret)"
        for level in 0..<60 { chain = "n\(level)=" + chain.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        started = clock.now
        let chained = ControlRedaction.scrub("https://h.example/c.json?\(chain)")
        #expect(!chained.contains(secret) && clock.now - started < .seconds(10))
        // recursion is bounded too: one level past maxNesting is running out like any other
        let budget = ControlRedaction.Budget(bytes: 1 << 20)
        func nest(_ depth: Int) throws -> Int { depth == 0 ? 0 : try budget.nested { try nest(depth - 1) + 1 } }
        #expect((try? nest(ControlRedaction.Budget.maxNesting)) == ControlRedaction.Budget.maxNesting)
        #expect(throws: ControlRedaction.Exhausted.self) { try nest(ControlRedaction.Budget.maxNesting + 1) }
        // negative controls, read to the end and kept exactly: "%" encoded 40 times, an ordinary address encoded 40
        // times, a large field with escapes, and the earlier ordinary strings
        var percent = "100%"
        var benign = "https://h.example/c.json?page=2"
        for _ in 0..<40 {
            percent = percent.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            benign = benign.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        let large = String(repeating: "Fake Game %41 50% done https://h.example/c.json?page=2 ", count: 4000)
        // ordinary redirects nested in redirects, each one different: an argument's worth six deep, and a large text
        // three deep throughout (what a per-byte allowance must cover once nothing is read twice)
        func redirect(_ index: Int, depth: Int) -> String {
            var address = "https://z\(index).example/?p=\(index)"
            for level in 0..<depth {
                address = "https://h\(level)x\(index).example/?next="
                    + address.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&n=\(index)"
            }
            return address
        }
        var argument = ""
        var index = 0
        while argument.count + redirect(index, depth: 6).count < 4096 {
            argument += redirect(index, depth: 6) + " "
            index += 1
        }
        let chains = (0..<300).map { redirect($0, depth: 3) }.joined(separator: " ")
        #expect(argument.count > 3000 && chains.utf8.count > 60_000)
        for text in [argument, chains, percent, benign, large, "50% done", "%2525", "https://h.example/?next=https%3A%2F%2Fa.example%2F%3Fpage%3D2"] {
            #expect(ControlRedaction.scrub(text) == text, "\(text.prefix(80))")
            #expect(!ControlRedaction.exhausts(text))
        }
    }

    /// The Sources check reads as redaction does: an address redaction would hide whole is refused, quoting nothing
    /// of it; a credential name encoded however deep is found; ordinary names and values, however deep, are accepted.
    @Test func theSourcesCheckRefusesWhatRedactionCanNotRead() throws {
        func problem(_ address: String) throws -> String? {
            RepositoryAddress.secretQueryProblem(try #require(URL(string: address)))
        }
        var name = "token"
        var value = "a/b"
        for _ in 0..<30 {
            name = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.subtracting(.letters))!
            value = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        #expect(try problem("https://h.example/c.json?\(name)=S3CR3T")?.contains("“token”") == true)
        var unreadable = "%3Ftoken%3DS3CR3T"
        for _ in 0..<1000 { unreadable = unreadable.replacingOccurrences(of: "%", with: "%25") }
        for address in ["https://h.example/c.json?q=\(unreadable)", "https://h.example/c.json?\(unreadable)=1"] {
            #expect(ControlRedaction.exhausts(address))
            let message = try #require(try problem(address))
            #expect(message.contains("encoded over and over") && !message.contains("S3CR3T"))
        }
        // negative controls: deep but ordinary
        #expect(try problem("https://h.example/c.json?q=\(value)&page=2") == nil)
        var page = "page"
        for _ in 0..<30 { page = page.addingPercentEncoding(withAllowedCharacters: .alphanumerics.subtracting(.letters))! }
        #expect(try problem("https://h.example/c.json?\(page)=2") == nil)
    }

    // MARK: - 7. Each window request is answered for itself

    @Test func anAnswerForALaterWindowNeverStandsForAnEarlierOne() async throws {
        let (library, _) = try fixture()
        library.windowOpenTimeout = .milliseconds(300)
        let sources = Task { @MainActor in await library.controlOpen(.sources) }
        while !library.windowRequests.contains(where: { $0.window == .sources }) { await Task.yield() }
        let settings = Task { @MainActor in await library.controlOpen(.settings) }
        while !library.windowRequests.contains(where: { $0.window == .settings }) { await Task.yield() }
        // a view that saw only the latest request and answered it alone
        let latest = try #require(library.windowRequests.last)
        library.windowRequestsOpened.insert(latest.serial)
        library.windowRequests.removeAll { $0.serial == latest.serial }
        library.controlHub?.notify()
        #expect(await settings.value == true)
        #expect(await sources.value == false)
        // the unanswered request is withdrawn: it can't open later behind a call that said it didn't
        #expect(library.windowRequests.isEmpty)
        #expect(library.windowRequestsOpened.isEmpty)
    }

    @Test func rootViewOpensAndAnswersEveryQueuedRequest() async throws {
        let (library, _) = try fixture()
        library.windowOpenTimeout = .seconds(5)
        final class Opened { var windows: [ControlWindow] = [] }
        let opened = Opened()
        let a = Task { @MainActor in await library.controlOpen(.sources) }
        let b = Task { @MainActor in await library.controlOpen(.settings) }
        let c = Task { @MainActor in await library.controlOpen(.changelog) }
        while library.windowRequests.count < 3 { await Task.yield() }
        // RootView's onChange, once for all three (what a coalesced update looks like)
        library.openRequestedWindows { opened.windows.append($0) }
        let (ra, rb, rc) = (await a.value, await b.value, await c.value)
        #expect(ra && rb && rc)
        #expect(opened.windows == [.sources, .settings, .changelog])
        #expect(library.windowRequests.isEmpty)
        // nothing queued: nothing opened
        library.openRequestedWindows { opened.windows.append($0) }
        #expect(opened.windows.count == 3)
    }

    // MARK: - 8. Booleans stay booleans

    @Test func parsedBooleansStayBooleans() async throws {
        let parsed = try ControlJSON.parse(Data(#"{"on":true,"off":false,"n":1,"z":0,"f":1.5,"a":[true,1,false,0]}"#.utf8))
        #expect(ControlJSON.text(parsed) == #"{"a":[true,1,false,0],"f":1.5,"n":1,"off":false,"on":true,"z":0}"#)
        #expect(String(decoding: ControlJSON.data(parsed), as: UTF8.self) == ControlJSON.text(parsed))
        // Swift's own values as before
        #expect(ControlJSON.text(["b": true, "i": 1, "d": 2.5] as [String: Any]) == #"{"b":true,"d":2.5,"i":1}"#)
        // a job's kept arguments can be sent again as they are
        let (_, api) = try fixture()
        let args = try #require(try ControlJSON.parse(Data(#"{"on":true}"#.utf8)) as? [String: Any])
        let (status, json) = await api.invoke("ui.console_mode", args: args, waitDone: true, timeout: 2000)
        #expect(status == 200)
        let jobID = try #require(json["job_id"] as? String)
        let job = try #require(api.hub.job(jobID))
        let kept = ControlJSON.text(api.hub.json(job)["args"] as Any)
        #expect(kept == #"{"on":true}"#)
        let again = try #require(try ControlJSON.parse(Data(kept.utf8)) as? [String: Any])
        #expect(await api.invoke("ui.console_mode", args: again, waitDone: true, timeout: 2000).0 == 200)
    }
}
