import Foundation
import Observation

/// What a command did: answered at once, or started work the library runs and reports on its own.
@MainActor enum ControlOutcome {
    case value(Any)
    /// An nxplay run (build, IPA, Mac app, install, play): the library's own Job, followed until it ends.
    case build(Job, Any)
    /// A Sources download's run: its id in Repositories.downloads and which attempt (a Retry keeps the id).
    case download(String, attempt: Int, Any)
    /// Settings › Devices › Install NX Play: the run with this id (IOSAppInstall.id).
    case iosApp(UUID, Any)
}

/// A call as a job. Every call is one; most end as they answer. One that started library work follows it by
/// reference: the very Job object, or the download's id. Its state is read from there, not kept twice, and is frozen
/// the moment it ends, so a later run (a Retry reuses a download's id) is never mistaken for this one.
@MainActor final class ControlJob {
    enum State: String, Sendable {
        case queued, running, cancelling, succeeded, failed, cancelled
        var isFinal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    }

    enum Follows {
        case nothing
        case build(Job)
        case download(String, attempt: Int)
        case iosApp(UUID)
    }

    let id: String
    let command: String
    /// The arguments with any secret-looking value shown as `***`.
    let args: Any
    /// What that took out of them: hidden wherever else the job shows it (its answer, error, progress and outcome).
    let removed = ControlRedaction.Removed()
    let created = Date.now
    fileprivate(set) var follows = Follows.nothing
    /// The call itself hasn't answered yet.
    fileprivate(set) var calling = true
    fileprivate(set) var answer: Any?
    fileprivate(set) var error: ControlError?
    fileprivate(set) var cancelRequested = false
    fileprivate(set) var final: State?
    fileprivate(set) var finished: Date?
    /// The followed work's last report, while it runs and as it ended.
    fileprivate(set) var progress: [String: Any]?
    fileprivate(set) var outcome: Any?

    init(id: String, command: String, args: Any) {
        self.id = id
        self.command = command
        // twice: a secret one argument held is hidden in the others too (a name repeating a token)
        self.args = removed.hideStrings(ControlRedaction.redact(args, removed: removed))
    }

    /// `value` as the job may show it: scrubbed of credentials, and without anything taken out of its arguments.
    func clean(_ value: Any) -> Any { removed.hideStrings(ControlRedaction.scrubStrings(value)) }
    func cleanText(_ text: String) -> String { removed.hide(ControlRedaction.scrub(text)) }
}

/// The jobs and the event log, both on the main actor with the library. Changes are seen through Observation
/// (ControlWatcher) and through the calls themselves; waiters (long polls, calls waiting for their job) wake on each.
@MainActor final class ControlHub {
    static let keptJobs = 256
    static let keptEvents = 2000
    static let maxWait: Duration = .seconds(600)

    private unowned let library: Library
    private(set) var jobs: [ControlJob] = []
    private var counter = 0
    private(set) var events: [(seq: Int, name: String, at: Date, data: [String: Any])] = []
    private(set) var lastSeq = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(library: Library) {
        self.library = library
    }

    // MARK: - Jobs

    func newJob(command: String, args: Any) -> ControlJob {
        counter += 1
        let job = ControlJob(id: "job-\(counter)", command: command, args: args)
        jobs.append(job)
        trim()
        emit("job", ["job": job.id, "command": command, "state": "running"], for: job)
        return job
    }

    func job(_ id: String) -> ControlJob? { jobs.first { $0.id == id } }

    /// The call answered: what it answered, and what it follows from now on.
    func answered(_ job: ControlJob, _ outcome: ControlOutcome) {
        job.calling = false
        switch outcome {
        // every answer is scrubbed, whatever it follows: a download's may quote its catalog's address
        case .value(let value):
            job.answer = job.clean(value)
        case .build(let run, let value):
            job.answer = job.clean(value)
            job.follows = .build(run)
        case .download(let id, let attempt, let value):
            job.answer = job.clean(value)
            job.follows = .download(id, attempt: attempt)
        case .iosApp(let id, let value):
            job.answer = job.clean(value)
            job.follows = .iosApp(id)
        }
        update(job)
        notify()
    }

    func failed(_ job: ControlJob, _ error: ControlError) {
        job.calling = false
        // a refusal may quote what it refused (an address with a credential in it, or only its secret-looking name
        // decoded, `token=…`): kept scrubbed, like the args, and without anything taken out of them
        job.error = ControlError(
            code: error.code, status: error.status, message: job.cleanText(error.message),
            details: error.details?.mapValues(job.cleanText))
        update(job)
        notify()
    }

    /// The job's state now: the followed work's, `cancelling` once a cancel went in and the work hasn't ended.
    func state(_ job: ControlJob) -> ControlJob.State {
        if let final = job.final { return final }
        if job.calling { return job.cancelRequested ? .cancelling : .running }
        if job.error != nil { return .failed }
        let live: ControlJob.State
        switch job.follows {
        case .nothing: live = .succeeded
        case .build(let run):
            switch run.status {
            case .queued: live = .queued
            case .running: live = .running
            case .succeeded: live = .succeeded
            case .failed: live = .failed
            case .cancelled: live = .cancelled
            }
        case .download(let id, let attempt):
            // this run, also once a Retry replaced it (the backend keeps it as it ended)
            switch library.repositories.run(id, attempt: attempt)?.state {
            case .queued?: live = .queued
            case .running?, .verifying?: live = .running
            case .succeeded?: live = .succeeded
            case .failed?: live = .failed
            case .cancelled?: live = .cancelled
            // its record is gone (trimmed) without this job seeing it end: nothing to say it succeeded
            case nil: live = .failed
            }
        case .iosApp(let id):
            // the run itself, also after a later run replaced it (kept as it ended); unknown: nothing says it worked
            guard let install = library.iosAppInstall(id: id) else { live = .failed; break }
            switch install.state {
            case .running: live = .running
            case .succeeded: live = .succeeded
            case .failed: live = .failed
            }
        }
        if !live.isFinal, job.cancelRequested { return .cancelling }
        return live
    }

    /// Reads the followed work again: its progress, and its end, once. Returns whether the state changed.
    @discardableResult
    func update(_ job: ControlJob) -> Bool {
        guard job.final == nil else { return false }
        let before = job.progress?["state"] as? String
        let state = state(job)
        var progress: [String: Any] = ["state": state.rawValue]
        switch job.follows {
        case .nothing: break
        case .build(let run):
            progress["fraction"] = (run.progressFraction * 100).rounded() / 100
            progress["text"] = run.progressText
            progress["game"] = run.game.folder.lastPathComponent
            if run.ask != nil { progress["waitingFor"] = "update_question" }
            if case .failed(let code) = run.status {
                progress["exitCode"] = Int(code)
                progress["lastLines"] = Array(
                    run.log.lines.suffix(40).map(\.text).filter { !$0.isEmpty }.suffix(8))
            }
        case .download(let id, let attempt):
            if let download = library.repositories.run(id, attempt: attempt) {
                progress["fraction"] = (download.fraction * 100).rounded() / 100
                progress["bytesDone"] = download.bytesDone
                progress["totalBytes"] = download.totalBytes
                progress["message"] = download.message ?? NSNull()
                progress["download"] = id
                progress["attempt"] = attempt
            }
        case .iosApp(let id):
            if let install = library.iosAppInstall(id: id) {
                progress["text"] = install.status
                if install.state == .failed { progress["lastLines"] = install.lastLines }
            }
        }
        // a run's message and last lines can quote an address too
        job.progress = job.clean(progress) as? [String: Any] ?? progress
        if state.isFinal {
            job.final = state
            job.finished = .now
            job.outcome = outcome(job).map(job.clean)
        }
        let changed = before != state.rawValue
        if changed || state.isFinal {
            var data: [String: Any] = ["job": job.id, "command": job.command, "state": state.rawValue]
            if let error = job.error { data["error"] = error.json }
            emit("job", data, for: job)
        }
        return changed
    }

    private func outcome(_ job: ControlJob) -> Any? {
        switch job.follows {
        case .build(let run): return library.remoteJSON(run)
        case .download(let id, let attempt):
            return library.repositories.run(id, attempt: attempt).map(library.remoteJSON) ?? NSNull()
        case .iosApp: return job.progress
        case .nothing: return nil
        }
    }

    /// Asks the followed work to stop through the library's own cancel. Sent at once: every command has started its
    /// work (or refused) by the time it answers, and a call that hasn't answered has nothing that can be cancelled.
    func cancel(_ job: ControlJob) throws(ControlError) -> Bool {
        update(job)
        if job.final != nil {
            throw ControlError(code: "already_finished", status: 409, message: "\(job.id) has already ended")
        }
        switch job.follows {
        case .build(let run):
            job.cancelRequested = true
            run.cancel()
        case .download(let id, let attempt):
            job.cancelRequested = true
            // this run only: a Retry's new run is someone else's
            library.repositories.cancel(id, attempt: attempt)
        case .nothing, .iosApp:
            throw ControlError(
                code: "not_cancellable", status: 409,
                message: "\(job.command) can't be cancelled: it ends on its own")
        }
        update(job)
        notify()
        return job.final == nil
    }

    func json(_ job: ControlJob, full: Bool = true) -> [String: Any] {
        update(job)
        var json: [String: Any] = [
            "id": job.id, "command": job.command, "state": state(job).rawValue, "created": job.created,
            "finished": job.finished ?? NSNull(), "cancelRequested": job.cancelRequested,
            "progress": job.progress ?? NSNull(),
        ]
        switch job.follows {
        case .nothing: json["follows"] = NSNull()
        case .build(let run): json["follows"] = ["kind": "build", "game": run.game.folder.lastPathComponent]
        case .download(let id, let attempt): json["follows"] = ["kind": "download", "download": id, "attempt": attempt]
        case .iosApp: json["follows"] = ["kind": "ios_app"]
        }
        json["cancellable"] = {
            switch job.follows {
            case .build, .download: job.final == nil
            default: false
            }
        }()
        if full {
            json["args"] = job.args
            json["result"] = job.answer ?? NSNull()
            json["outcome"] = job.outcome ?? NSNull()
            json["error"] = job.error?.json ?? NSNull()
        }
        return json
    }

    /// Re-reads every unfinished job. Called by the watcher on every change it sees. A job follows its download's
    /// run, not just its id, so a Retry from anywhere (the Sources window, the iOS app, a call) can't be taken for
    /// the run it followed, however late this runs.
    func updateAll() {
        var changed = false
        for job in jobs where job.final == nil { changed = update(job) || changed }
        if changed { notify() }
    }

    private func trim() {
        while jobs.count > Self.keptJobs, let index = jobs.firstIndex(where: { $0.final != nil }) {
            jobs.remove(at: index)
        }
    }

    // MARK: - Events

    /// Every event is kept through here, whoever emits it (a job's state, or the watcher's picture of the library:
    /// a search, a download's message, a build's text, an install's status), and only as it may be shown: each string
    /// in it scrubbed of credentials the way a job's answer is, so no producer can keep one by forgetting to. An event
    /// about a job also loses what that job's arguments hid (`ControlJob.removed`), except the hub's own words for it
    /// (`jobWords`), which the hub wrote, not the caller. The scrubbed copy is all that's kept: never the raw data, nor
    /// the job, which the log outlives.
    func emit(_ name: String, _ data: [String: Any], for job: ControlJob? = nil) {
        lastSeq += 1
        events.append((lastSeq, name, .now, Self.clean(data, for: job)))
        if events.count > Self.keptEvents { events.removeFirst(events.count - Self.keptEvents) }
        notify()
    }

    /// A job event's id, command and state: the hub's own (a generated id, a registered name, a state's name).
    static let jobWords: Set<String> = ["job", "command", "state"]

    static func clean(_ data: [String: Any], for job: ControlJob?) -> [String: Any] {
        guard let job else { return data.mapValues(ControlRedaction.scrubStrings) }
        var cleaned: [String: Any] = [:]
        for (key, value) in data {
            cleaned[key] = jobWords.contains(key) ? ControlRedaction.scrubStrings(value) : job.clean(value)
        }
        return cleaned
    }

    /// The largest cursor a client may pass back: every `next_after` the API gives fits, and so does any count of
    /// events this process could reach. Callers refuse a cursor outside 0…maxCursor before asking.
    static let maxCursor = Int(Int32.max)

    func events(after: Int, names: Set<String>?, limit: Int) -> [String: Any] {
        // clamped, and no arithmetic on `after`: a cursor near Int.max must not overflow (a trap ends the app)
        let after = min(max(after, 0), Self.maxCursor)
        let limit = max(1, limit)
        let oldest = events.first?.seq ?? (lastSeq + 1)  // ≥ 1
        let matching = events.filter { $0.seq > after && (names?.contains($0.name) ?? true) }.prefix(limit)
        let next = matching.count == limit ? (matching.last?.seq ?? after) : max(after, lastSeq)
        return [
            "events": matching.map { ["seq": $0.seq, "name": $0.name, "at": $0.at, "data": $0.data] },
            "next_after": next,
            // some events after `after` were dropped from the log before they were read
            "missed": after < oldest - 1 && after < lastSeq,
        ]
    }

    // MARK: - Waiting

    /// Wakes every waiter: something changed.
    func notify() {
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }

    /// Waits until `done` holds or `timeout` passes, waking on each change.
    func wait(timeout: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + min(timeout, Self.maxWait)
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            let id = UUID()
            let remaining = deadline - ContinuousClock.now
            let timer = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                self?.wake(id)
            }
            await withCheckedContinuation { continuation in waiters[id] = continuation }
            timer.cancel()
        }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
