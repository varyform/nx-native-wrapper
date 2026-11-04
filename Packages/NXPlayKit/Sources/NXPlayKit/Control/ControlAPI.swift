import Foundation

/// The control API: routes, the guards every request passes first, calls as jobs, events, and MCP (ControlMCP.swift).
///
///     GET  /v1/status                        the app, the API, the library
///     GET  /v1/commands[?query=&group=]      every command, in short
///     GET  /v1/commands/<name>               one command in full, with its input schema
///     POST /v1/invoke                        {command, args?, wait?: "answer"|"done", timeout_ms?}
///     GET  /v1/jobs, GET /v1/jobs/<id>[?wait_ms=]
///     POST /v1/jobs/<id>/cancel
///     GET  /v1/events[?after=&names=a,b&limit=&wait_ms=]
///     GET  /v1/settings, POST /v1/settings  {patch}
///     GET  /v1/limitations
///     POST /mcp                              MCP JSON-RPC
///
/// Every request needs `Authorization: Bearer <token>` (endpoint.json) and `Host: 127.0.0.1:<port>` or
/// `localhost:<port>` (a DNS-rebound name is refused). A request a web page could make is refused: any `Origin` or
/// `Sec-Fetch-*` header, `OPTIONS`, a POST that isn't `application/json`. No CORS header is ever sent, and nothing
/// redirects.
@MainActor final class ControlAPI {
    static let maxCalling = 32
    static let defaultTimeout = 30_000
    static let maxEventWait = 30_000

    private unowned let library: Library
    let endpoint: ControlEndpointFile
    let hub: ControlHub
    private let token = ControlCredential.newToken()
    private var server: ControlServer?
    private var watcher: ControlWatcher?
    private(set) var port: UInt16?
    private(set) var problem: String?
    private(set) lazy var commands: [ControlCommand] = library.controlCommands()
    private lazy var byName: [String: ControlCommand] = Dictionary(
        uniqueKeysWithValues: commands.map { ($0.name, $0) })
    private lazy var byTool: [String: ControlCommand] = Dictionary(
        uniqueKeysWithValues: commands.map { ($0.toolName, $0) })
    let started = Date.now

    init(library: Library, endpoint: ControlEndpointFile) {
        self.library = library
        self.endpoint = endpoint
        hub = ControlHub(library: library)
    }

    /// Tests read the token here; nothing else hands it out.
    var tokenForTests: String { token }

    func start(port: UInt16) {
        let server = ControlServer { [weak self] request in
            await self?.respond(to: request) ?? .error(ControlError(code: "unavailable", status: 503, message: "NX Play is quitting"))
        }
        server.onReady = { [weak self] port in self?.ready(port) }
        server.onFailure = { [weak self] problem in
            self?.problem = problem
            self?.port = nil
            if let self { self.endpoint.remove(token: self.token) }
        }
        self.server = server
        let watcher = ControlWatcher(library: library, hub: hub)
        self.watcher = watcher
        watcher.start()
        server.start(port: port)
    }

    private func ready(_ port: UInt16) {
        self.port = port
        do {
            try endpoint.write(descriptor(port: port))
            problem = nil
        } catch {
            // no descriptor, no way in: stop rather than listen with a token nobody can read safely
            problem = error.localizedDescription
            server?.stop()
            self.port = nil
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        server?.stop()
        server = nil
        port = nil
        endpoint.remove(token: token)
        hub.notify()
    }

    private func descriptor(port: UInt16) -> [String: Any] {
        let url = "http://127.0.0.1:\(port)"
        return [
            "schema": ControlEndpointFile.schema, "url": url, "mcp_url": url + "/mcp", "port": Int(port),
            "token": token, "pid": Int(getpid()), "app_version": Self.appVersion,
            "bundle_id": Bundle.main.bundleIdentifier ?? "", "started_ms": Int(started.timeIntervalSince1970 * 1000),
        ]
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - Guards

    func respond(to request: ControlRequest) async -> ControlResponse {
        if let refusal = refusal(request) { return .error(refusal) }
        do {
            return try await route(request)
        } catch {
            return .error(error)
        }
    }

    /// Why a request is refused before it's routed, nil when it may go on.
    func refusal(_ request: ControlRequest) -> ControlError? {
        let headers = request.headers
        if headers["origin"] != nil || headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) {
            return ControlError(
                code: "browser_request_forbidden", status: 403,
                message: "Requests from web pages aren't accepted (an Origin or Sec-Fetch header)")
        }
        guard let port, let host = headers["host"]?.lowercased(),
            host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
        else {
            return ControlError(code: "bad_host", status: 403, message: "The Host header must be 127.0.0.1:<port> or localhost:<port>")
        }
        if request.method == "OPTIONS" {
            return ControlError(code: "method_not_allowed", status: 405, message: "OPTIONS isn't accepted: no cross-origin requests")
        }
        guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer "),
            ControlCredential.matches(String(authorization.dropFirst("Bearer ".count)), token)
        else {
            return ControlError(code: "unauthorized", status: 401, message: "A bearer token from the control API's endpoint.json is needed")
        }
        if request.method == "POST" {
            let type = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "application/json" else {
                return ControlError(code: "unsupported_media_type", status: 415, message: "POST bodies must be application/json")
            }
        }
        return nil
    }

    // MARK: - Routes

    private func route(_ request: ControlRequest) async throws(ControlError) -> ControlResponse {
        let route = request.route
        if route("GET", "v1/status") != nil { return .json(["ok": true, "result": statusJSON()]) }
        if route("GET", "v1/commands") != nil {
            return .json(["ok": true, "result": listCommands(query: request.query["query"] ?? request.query["q"], group: request.query["group"])])
        }
        if let name = route("GET", "v1/commands/*")?.first {
            guard let command = byName[name] else { throw unknownCommand(name) }
            return .json(["ok": true, "result": command.fullJSON])
        }
        if route("POST", "v1/invoke") != nil {
            let body = try object(request.body)
            guard let name = body["command"] as? String else { throw .invalidArgs("command is missing") }
            var envelope = body
            let args = envelope.removeValue(forKey: "args") ?? [String: Any]()
            if let problem = ControlParam.problem(envelope, Self.invokeEnvelope, at: "") { throw .invalidArgs(problem) }
            let (status, json) = await invoke(
                name, args: args, waitDone: body["wait"] as? String == "done",
                timeout: (body["timeout_ms"] as? NSNumber)?.intValue ?? Self.defaultTimeout)
            return .json(json, status: status)
        }
        if route("GET", "v1/jobs") != nil {
            return .json(["ok": true, "result": hub.jobs.reversed().map { hub.json($0, full: false) }])
        }
        if let id = route("GET", "v1/jobs/*")?.first {
            let wait = try Self.queryInt(request.query, "wait_ms", default: 0, in: 0...600_000)
            return .json(["ok": true, "result": try await jobJSON(id, waitMS: wait)])
        }
        if let id = route("POST", "v1/jobs/*/cancel")?.first {
            return .json(try cancelJob(id))
        }
        if route("GET", "v1/events") != nil {
            let names = request.query["names"].map { Set($0.split(separator: ",").map(String.init)) }
            // the same bounds as nxapi_events' schema: a cursor out of range is the client's error, never arithmetic
            let after = try Self.queryInt(request.query, "after", default: 0, in: 0...ControlHub.maxCursor)
            let limit = try Self.queryInt(request.query, "limit", default: 200, in: 1...1000)
            let wait = try Self.queryInt(request.query, "wait_ms", default: 0, in: 0...Self.maxEventWait)
            return .json(["ok": true, "result": await events(after: after, names: names, limit: limit, waitMS: wait)])
        }
        if route("GET", "v1/settings") != nil {
            return .json(["ok": true, "result": library.controlSettingsJSON()])
        }
        if route("POST", "v1/settings") != nil {
            let body = try object(request.body)
            guard let patch = body["patch"] else { throw .invalidArgs("patch is missing") }
            let (status, json) = await invoke("settings.update", args: ["patch": patch], waitDone: true, timeout: Self.defaultTimeout)
            return .json(json, status: status)
        }
        if route("GET", "v1/limitations") != nil { return .json(["ok": true, "result": Self.limitations]) }
        if route("POST", "mcp") != nil { return await ControlMCP(api: self).respond(request.body, headers: request.headers) }
        if request.path.first == "mcp" || request.path.first == "v1" {
            throw ControlError(code: "method_not_allowed", status: 405, message: "\(request.method) isn't accepted on \(request.pathText)")
        }
        throw .notFound("No such API: \(request.method) \(request.pathText)")
    }

    /// /v1/invoke's body besides `args` (which the command's own parameters check).
    static let invokeEnvelope = [
        ControlParam("command", .string(maxLength: 128), "The command's name"),
        ControlParam("wait", .string(choices: ["answer", "done"]), required: false, "Answer when the call has, or when its work has ended too"),
        ControlParam("timeout_ms", .integer(min: 0, max: 600_000), required: false, "The longest to wait (default 30000)"),
    ]

    /// A query parameter that must be a whole number in `range` when given: anything else is refused (400), never
    /// read as the default or clamped from an overflowing value.
    static func queryInt(_ query: [String: String], _ name: String, default value: Int, in range: ClosedRange<Int>)
        throws(ControlError) -> Int
    {
        guard let text = query[name] else { return value }
        guard let number = Int(text), range.contains(number) else {
            throw .invalidArgs("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }

    private func object(_ body: Data) throws(ControlError) -> [String: Any] {
        guard let object = try ControlJSON.parse(body) as? [String: Any] else {
            throw ControlError(code: "invalid_json", status: 400, message: "The body must be a JSON object")
        }
        return object
    }

    private func unknownCommand(_ name: String) -> ControlError {
        ControlError(code: "unknown_command", status: 404, message: "No command \(name): see GET /v1/commands")
    }

    // MARK: - Calls

    func command(named name: String) -> ControlCommand? { byName[name] }
    func command(tool: String) -> ControlCommand? { byTool[tool] }

    /// Runs a command as a job. Answers when it has answered (`wait` "answer", the default) or when its work has
    /// ended too ("done"), at most `timeout` ms: 200 with the result when the job has ended, 202 with the job while
    /// its work goes on, or the command's error.
    func invoke(_ name: String, args: Any, waitDone: Bool, timeout: Int) async -> (Int, [String: Any]) {
        guard let command = byName[name] else { return errorJSON(unknownCommand(name)) }
        guard let values = args as? [String: Any] else { return errorJSON(.invalidArgs("args must be an object")) }
        if let problem = ControlParam.problem(values, command.params, at: "") { return errorJSON(.invalidArgs(problem)) }
        guard hub.jobs.filter(\.calling).count < Self.maxCalling else {
            return errorJSON(ControlError(code: "too_many_jobs", status: 429, message: "\(Self.maxCalling) calls are unfinished already"))
        }
        let job = hub.newJob(command: name, args: values)
        let hub = hub
        Task { @MainActor in
            do throws(ControlError) {
                hub.answered(job, try await command.run(ControlArgs(values: values)))
            } catch {
                hub.failed(job, error)
            }
        }
        let limit = Duration.milliseconds(max(0, min(timeout, 600_000)))
        await hub.wait(timeout: limit) { waitDone ? hub.state(job).isFinal : !job.calling }
        return jobAnswer(job)
    }

    func jobAnswer(_ job: ControlJob) -> (Int, [String: Any]) {
        if let error = job.error {
            var json = errorJSON(error).1
            json["job_id"] = job.id
            return (error.status, json)
        }
        let state = hub.state(job)
        if job.calling || !state.isFinal {
            return (202, ["ok": true, "job_id": job.id, "result": job.answer ?? NSNull(), "job": hub.json(job, full: false)])
        }
        var json: [String: Any] = ["ok": state == .succeeded, "job_id": job.id, "result": job.answer ?? NSNull(), "state": state.rawValue]
        if let outcome = job.outcome { json["outcome"] = outcome }
        if state != .succeeded {
            json["error"] = ControlError(code: "job_\(state.rawValue)", status: 422, message: "\(job.command) \(state.rawValue)").json
        }
        return (200, json)
    }

    private func errorJSON(_ error: ControlError) -> (Int, [String: Any]) {
        (error.status, ["ok": false, "error": error.json])
    }

    func jobJSON(_ id: String, waitMS: Int) async throws(ControlError) -> [String: Any] {
        guard let job = hub.job(id) else { throw ControlError(code: "job_not_found", status: 404, message: "No job \(id)") }
        if waitMS > 0 {
            await hub.wait(timeout: .milliseconds(min(waitMS, 600_000))) { self.hub.state(job).isFinal }
        }
        return hub.json(job)
    }

    func cancelJob(_ id: String) throws(ControlError) -> [String: Any] {
        guard let job = hub.job(id) else { throw ControlError(code: "job_not_found", status: 404, message: "No job \(id)") }
        let pending = try hub.cancel(job)
        return ["ok": true, "pending": pending, "job": hub.json(job, full: false)]
    }

    func events(after: Int, names: Set<String>?, limit: Int, waitMS: Int) async -> [String: Any] {
        let limit = max(1, min(limit, 1000))
        func matching() -> Bool { hub.events.contains { $0.seq > after && (names?.contains($0.name) ?? true) } }
        if waitMS > 0, !matching() {
            await hub.wait(timeout: .milliseconds(min(waitMS, Self.maxEventWait))) { matching() || self.server == nil }
        }
        return hub.events(after: after, names: names, limit: limit)
    }

    func listCommands(query: String?, group: String?) -> [[String: Any]] {
        let words = (query ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return commands.filter { command in
            (group == nil || command.group == group)
                && words.allSatisfy { command.name.lowercased().contains($0) || command.summary.lowercased().contains($0) }
        }.map(\.summaryJSON)
    }

    func statusJSON() -> [String: Any] {
        [
            "app": [
                "name": "NX Play", "version": Self.appVersion, "bundle_id": Bundle.main.bundleIdentifier ?? "",
                "pid": Int(getpid()),
            ],
            "api": [
                "schema": ControlEndpointFile.schema, "commands": commands.count, "port": port.map { Int($0) } ?? NSNull(),
                "last_event": hub.lastSeq, "jobs_active": hub.jobs.filter { !hub.state($0).isFinal }.count,
                "started": started,
            ],
            "library": library.controlStatusJSON(),
        ]
    }

    static let limitations: [String: Any] = [
        "not_available": [
            "Native file and folder pickers: every command takes the path itself (library.inspect_folder, library.set_folder, settings.update cloudSaves/saveBackupPath).",
            "Setup (installs Homebrew packages, nxnative and Python with an administrator password), Uninstall and app updates stay in the window.",
            "The iOS app's server (turning it on, its port, a new pairing code) stays in Settings › Devices; companion.status reads it. Its pairing code is never shown or accepted here.",
            "Sources' access tokens are set in the Sources window only; sources.list says whether one is saved, never what it is.",
            "nxnativePath and keysPath are read only here: they name the code builds run and the keys they read.",
            "Transfer Saves and the save backup's repository setup are window flows.",
            "Show in Finder, Open Mac App and the other Finder actions aren't commands.",
            "nxnative Notes (a game's profile notes) stays in the window: games.get says whether a game has a profile and how many changes it brings.",
            "ui.open needs the main window open to open another one (it brings NX Play forward either way).",
        ],
        "never": [
            "No command runs a shell or a program it's given, reads or writes an arbitrary file, or returns a key, token or pairing code.",
        ],
    ]
}
