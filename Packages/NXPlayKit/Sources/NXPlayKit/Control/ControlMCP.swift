import Foundation

/// MCP over the control API (POST /mcp, JSON answers, no event stream; the stdio adapter forwards to it):
/// `initialize`, `ping`, `tools/list` and `tools/call`. One tool per command (`nx_<command>`, the command's parameters
/// as its input schema, its effect as annotations) and the `nxapi_*` tools for jobs, events and discovery.
@MainActor struct ControlMCP {
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let instructions = """
        Controls the running NX Play (Switch games built for this Mac) with the library its window shows. Tools named \
        nx_<command> run NX Play's own operations; nxapi_* list and describe them and follow jobs and events. Start with \
        nxapi_status, then nx_games_list. Builds, installs, plays and downloads answer with a job at once: follow it with \
        nxapi_job (wait_ms) or nxapi_events, stop it with nxapi_cancel_job. games.remove and cleanup.delete delete \
        files for good and need an explicit confirmation argument; sources.remove takes only the source (its \
        downloaded files stay). See nxapi_limitations.
        """

    let api: ControlAPI

    func respond(_ body: Data, headers: [String: String]) async -> ControlResponse {
        let message: Any
        do {
            message = try ControlJSON.parse(body)
        } catch {
            return .json(Self.error(nil, -32700, "Parse error: the body isn't JSON"))
        }
        if message is [Any] { return .json(Self.error(nil, -32600, "Batches aren't accepted: send one message")) }
        guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0" else {
            return .json(Self.error(nil, -32600, "Not a JSON-RPC 2.0 message"))
        }
        let id = request["id"]
        guard let method = request["method"] as? String else {
            // a response or something else from the client: nothing to answer
            return id == nil || request["result"] != nil || request["error"] != nil
                ? .accepted : .json(Self.error(nil, -32600, "No method"))
        }
        guard let id else { return .accepted }  // a notification (initialized, cancelled…)
        guard id is String || (id as? NSNumber).map({ !ControlType.isBool($0) }) == true else {
            return .json(Self.error(nil, -32600, "The id must be a string or a number"))
        }
        if method != "initialize", let version = headers["mcp-protocol-version"], !Self.versions.contains(version) {
            return .json(Self.error(id, -32600, "Unsupported MCP-Protocol-Version \(version)"), status: 400)
        }
        let params = request["params"] ?? [String: Any]()
        guard let params = params as? [String: Any] else {
            return .json(Self.error(id, -32602, "params must be an object"))
        }
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return .json(Self.result(id, [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nxplay", "title": "NX Play", "version": ControlAPI.appVersion],
                "instructions": Self.instructions,
            ]))
        case "ping":
            return .json(Self.result(id, [String: Any]()))
        case "tools/list":
            return .json(Self.result(id, ["tools": tools()]))
        case "tools/call":
            guard let name = params["name"] as? String else { return .json(Self.error(id, -32602, "params.name is missing")) }
            let arguments = params["arguments"] ?? [String: Any]()
            guard let arguments = arguments as? [String: Any] else {
                return .json(Self.error(id, -32602, "params.arguments must be an object"))
            }
            guard let result = await call(name, arguments) else {
                return .json(Self.error(id, -32602, "Unknown tool: \(name)"))
            }
            return .json(Self.result(id, result))
        default:
            return .json(Self.error(id, -32601, "Method not found: \(method)"))
        }
    }

    static func result(_ id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: - Tools

    struct MetaTool {
        let name: String
        let summary: String
        let params: [ControlParam]
        let readOnly: Bool
        let destructive: Bool
    }

    static let metaTools: [MetaTool] = [
        MetaTool(name: "nxapi_status", summary: "NX Play, the API and the library at a glance", params: [], readOnly: true, destructive: false),
        MetaTool(
            name: "nxapi_list_commands", summary: "NX Play's commands in short",
            params: [ControlParam("query", .string(maxLength: 256), required: false, "Words in the name or summary"),
                     ControlParam("group", .string(maxLength: 64), required: false, "library, games, settings, sources, downloads, devices, cleanup, ui…")],
            readOnly: true, destructive: false),
        MetaTool(name: "nxapi_describe_command", summary: "One command in full, with its input schema", params: [ControlParam("name", .string(maxLength: 128), "games.extract, …")], readOnly: true, destructive: false),
        MetaTool(
            name: "nxapi_invoke", summary: "Run any command by name (the nx_* tools do the same, one per command)",
            params: [ControlParam("command", .string(maxLength: 128), "The command's name"),
                     ControlParam("args", .map(.anyValue, maxCount: 64), required: false, "Its arguments, as its input schema says"),
                     ControlParam("wait", .string(choices: ["answer", "done"]), required: false, "answer (default) or done: wait for its work to end"),
                     ControlParam("timeout_ms", .integer(min: 0, max: 600_000), required: false, "The longest to wait")],
            readOnly: false, destructive: true),
        MetaTool(name: "nxapi_jobs", summary: "The API's jobs, newest first", params: [], readOnly: true, destructive: false),
        MetaTool(
            name: "nxapi_job", summary: "One job: its state, progress, result",
            params: [ControlParam("job", .string(maxLength: 64), "job-…"), ControlParam("wait_ms", .integer(min: 0, max: 600_000), required: false, "Wait for it to end, at most this long")],
            readOnly: true, destructive: false),
        MetaTool(name: "nxapi_cancel_job", summary: "Stop a job's work through NX Play's own Cancel (builds, plays, installs, downloads)", params: [ControlParam("job", .string(maxLength: 64), "job-…")], readOnly: false, destructive: false),
        MetaTool(
            name: "nxapi_events", summary: "NX Play's events: jobs, builds, downloads, library, settings, sources, ui",
            params: [ControlParam("after", .integer(min: 0, max: Int(Int32.max)), required: false, "Pass next_after back"),
                     ControlParam("names", .array(.string(maxLength: 32), maxItems: 16), required: false, "Only these names"),
                     ControlParam("limit", .integer(min: 1, max: 1000), required: false, "At most this many (200)"),
                     ControlParam("wait_ms", .integer(min: 0, max: 30_000), required: false, "Wait for one, at most this long")],
            readOnly: true, destructive: false),
        MetaTool(name: "nxapi_limitations", summary: "What the API doesn't do, and what to use instead", params: [], readOnly: true, destructive: false),
    ]

    func tools() -> [[String: Any]] {
        api.commands.map { command in
            [
                "name": command.toolName, "title": command.summary,
                "description": "\(command.summary). NX Play command \(command.name)"
                    + (command.cancel.map { "; answers with a job, cancelled by \($0)" } ?? "") + ".",
                "inputSchema": command.inputSchema, "annotations": command.annotations,
            ]
        }
            + Self.metaTools.map { tool in
                [
                    "name": tool.name, "title": tool.summary, "description": tool.summary + ".",
                    "inputSchema": ControlParam.objectSchema(tool.params),
                    "annotations": [
                        "title": tool.summary, "readOnlyHint": tool.readOnly, "destructiveHint": tool.destructive,
                        "idempotentHint": tool.readOnly, "openWorldHint": false,
                    ],
                ]
            }
    }

    /// A tool's result, nil for an unknown tool. A refusal or failure is a result with `isError`, so the model sees why.
    func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any]? {
        if let command = api.command(tool: name) {
            let (_, json) = await api.invoke(command.name, args: arguments, waitDone: false, timeout: ControlAPI.defaultTimeout)
            return Self.toolResult(json)
        }
        guard let meta = Self.metaTools.first(where: { $0.name == name }) else { return nil }
        // nxapi_invoke's args are the command's to check
        var checked = arguments
        if meta.name == "nxapi_invoke" { checked["args"] = nil }
        if let problem = ControlParam.problem(checked, meta.params, at: "") {
            return Self.toolResult(["ok": false, "error": ControlError.invalidArgs(problem).json])
        }
        let args = ControlArgs(values: arguments)
        do throws(ControlError) {
            switch name {
            case "nxapi_status": return Self.toolResult(["ok": true, "result": api.statusJSON()])
            case "nxapi_list_commands":
                return Self.toolResult(["ok": true, "result": api.listCommands(query: args.string("query"), group: args.string("group"))])
            case "nxapi_describe_command":
                let wanted = args.string("name") ?? ""
                guard let command = api.command(named: wanted) ?? api.command(tool: wanted) else {
                    throw ControlError(code: "unknown_command", status: 404, message: "No command \(wanted)")
                }
                return Self.toolResult(["ok": true, "result": command.fullJSON])
            case "nxapi_invoke":
                guard arguments["args"] == nil || arguments["args"] is [String: Any] else { throw .invalidArgs("args must be an object") }
                let (_, json) = await api.invoke(
                    args.string("command") ?? "", args: arguments["args"] ?? [String: Any](),
                    waitDone: args.string("wait") == "done", timeout: args.int("timeout_ms") ?? ControlAPI.defaultTimeout)
                return Self.toolResult(json)
            case "nxapi_jobs":
                return Self.toolResult(["ok": true, "result": api.hub.jobs.reversed().map { api.hub.json($0, full: false) }])
            case "nxapi_job":
                return Self.toolResult(["ok": true, "result": try await api.jobJSON(args.string("job") ?? "", waitMS: args.int("wait_ms") ?? 0)])
            case "nxapi_cancel_job":
                return Self.toolResult(try api.cancelJob(args.string("job") ?? ""))
            case "nxapi_events":
                return Self.toolResult([
                    "ok": true,
                    "result": await api.events(
                        after: args.int("after") ?? 0, names: args.strings("names").map(Set.init),
                        limit: args.int("limit") ?? 200, waitMS: args.int("wait_ms") ?? 0),
                ])
            case "nxapi_limitations": return Self.toolResult(["ok": true, "result": ControlAPI.limitations])
            default: return nil
            }
        } catch {
            return Self.toolResult(["ok": false, "error": error.json])
        }
    }

    static func toolResult(_ json: [String: Any]) -> [String: Any] {
        let failed = json["ok"] as? Bool == false
        return [
            "content": [["type": "text", "text": ControlJSON.text(json)]],
            "structuredContent": ControlJSON.clean(json),
            "isError": failed,
        ]
    }
}
