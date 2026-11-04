import Foundation

/// One thing the control API can do: a name (`games.extract`), what it does, its parameters, and the library code it
/// runs. The list (Library+ControlCommands.swift) is the only one: the HTTP API, the MCP tools, the CLI and the stdio
/// adapter all read it from the running app.
@MainActor struct ControlCommand {
    enum Effect: String, Sendable {
        /// Changes nothing (it may look at the network or the devices again).
        case read
        /// Changes the library, a setting, the window, or starts work.
        case write
        /// Deletes something that can't be brought back.
        case destructive
    }

    let name: String
    let summary: String
    let params: [ControlParam]
    let effect: Effect
    /// Doing it twice is doing it once.
    let idempotent: Bool
    /// It reaches outside this Mac: a catalog server, a device.
    let openWorld: Bool
    /// How a job it starts is cancelled; nil when it ends on its own.
    let cancel: String?
    let run: @MainActor (ControlArgs) async throws(ControlError) -> ControlOutcome

    init(
        _ name: String, _ summary: String, params: [ControlParam] = [], effect: Effect,
        idempotent: Bool = false, openWorld: Bool = false, cancel: String? = nil,
        run: @escaping @MainActor (ControlArgs) async throws(ControlError) -> ControlOutcome
    ) {
        self.name = name
        self.summary = summary
        self.params = params
        self.effect = effect
        self.idempotent = idempotent || effect == .read
        self.openWorld = openWorld
        self.cancel = cancel
        self.run = run
    }

    var group: String { String(name.split(separator: ".").first ?? "") }

    /// The MCP tool's name: `nx_` and the command with dots as underscores (games.extract → nx_games_extract).
    var toolName: String { "nx_" + name.replacingOccurrences(of: ".", with: "_") }

    var inputSchema: [String: Any] { ControlParam.objectSchema(params) }

    var summaryJSON: [String: Any] {
        [
            "name": name, "group": group, "summary": summary, "effect": effect.rawValue,
            "params": params.map { $0.required ? $0.name : $0.name + "?" }, "tool": toolName,
        ]
    }

    var fullJSON: [String: Any] {
        [
            "name": name, "group": group, "summary": summary, "effect": effect.rawValue,
            "readOnly": effect == .read, "destructive": effect == .destructive, "idempotent": idempotent,
            "openWorld": openWorld, "cancel": cancel ?? NSNull(), "input_schema": inputSchema, "tool": toolName,
        ]
    }

    /// MCP's tool annotations: hints for the client, never a security boundary.
    var annotations: [String: Any] {
        [
            "title": summary, "readOnlyHint": effect == .read, "destructiveHint": effect == .destructive,
            "idempotentHint": idempotent, "openWorldHint": openWorld,
        ]
    }
}
