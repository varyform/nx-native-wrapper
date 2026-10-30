import AppKit
import GameController
import Observation

/// The game controllers as a remote for NX Play: the D-pad or left stick moves the selection (repeating while held),
/// A plays, B backs out, Menu toggles Console Mode. Every connected controller drives it, each with its own held
/// direction. Any controller GameController knows works: Joy-Con, Pro Controller, Xbox, DualShock / DualSense, 8BitDo.
/// macOS gives controller input only to the frontmost app, so a running game's input never reaches NX Play.
///
/// In a game each controller is a player of its own (nxnative's dm/host/front_mac.m): the first one connected is
/// player 1, together with the keyboard, the next player 2, up to 8. NX Play numbers them the same way, in the order
/// GameController lists them, which is the order the game takes them in when it starts, and lights each controller's
/// player lights to match.
@MainActor @Observable
public final class Gamepad {
    public enum Command: Sendable, Equatable {
        case left, right, up, down, confirm, back, menu
    }

    /// A connected controller as the top bar and Settings show it.
    public struct Player: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// 1…8 in a game; nil past the eighth, which nxnative leaves out.
        public let number: Int?
        public let battery: Float?
    }

    /// The controllers connected, in the order the game will take them.
    public private(set) var controllers: [GCController] = []
    /// The last one used: its button symbols are the hints'.
    public private(set) var current: GCController?
    /// nxnative's DM_PAD_MERGE: every controller is player 1.
    public var merged = false { didSet { lightPlayers() } }
    /// nxnative's DM_KBD_PLAYER=own: the keyboard is player 1 on its own, the controllers from player 2 on.
    public var keyboardOwnPlayer = false { didSet { lightPlayers() } }
    var onCommand: ((Command) -> Void)?

    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var held: [ObjectIdentifier: Command] = [:]
    @ObservationIgnored private var repeaters: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Screenshot mode: controllers to show, without any connected.
    var sample: [(name: String, battery: Float)] = []

    /// nxnative's players (front_mac.m): 8 at most.
    nonisolated static let maxPlayers = 8

    /// The game's player numbers for this many controllers, in order: all player 1 when merged, from player 2 when
    /// the keyboard has player 1 to itself, nil past the eighth player.
    nonisolated static func numbers(count: Int, merged: Bool, keyboardOwnPlayer: Bool) -> [Int?] {
        (0..<count).map { index in
            if merged { return 1 }
            let number = index + (keyboardOwnPlayer ? 2 : 1)
            return number <= maxPlayers ? number : nil
        }
    }

    public var players: [Player] {
        if !sample.isEmpty {
            let numbers = Self.numbers(
                count: sample.count, merged: merged, keyboardOwnPlayer: keyboardOwnPlayer)
            return sample.enumerated().map {
                Player(
                    id: "sample\($0.offset)", name: $0.element.name, number: numbers[$0.offset],
                    battery: $0.element.battery)
            }
        }
        let numbers = Self.numbers(
            count: controllers.count, merged: merged, keyboardOwnPlayer: keyboardOwnPlayer)
        return controllers.enumerated().map { index, controller in
            Player(
                id: "\(ObjectIdentifier(controller).hashValue)",
                name: Self.displayName(
                    vendor: controller.vendorName, category: controller.productCategory),
                number: numbers[index], battery: Self.battery(of: controller))
        }
    }

    /// The last used controller's name, for a single line.
    public var name: String? {
        sample.first?.name
            ?? (current ?? controllers.first).map {
                Self.displayName(vendor: $0.vendorName, category: $0.productCategory)
            }
    }

    /// The controller's own name, unless it is a generic one: an Xbox controller on a USB cable calls itself just
    /// "Controller" (its USB product name; "Xbox Wireless Controller" over Bluetooth), while GameController still
    /// knows its kind (productCategory "Xbox One"). Then the kind, worded as players know it.
    nonisolated static func displayName(vendor: String?, category: String) -> String {
        let vendor = vendor?.trimmingCharacters(in: .whitespaces) ?? ""
        let generic: Set<String> = ["", "controller", "gamepad", "game controller", "usb gamepad"]
        guard generic.contains(vendor.lowercased()) else { return vendor }
        switch category {
        case GCProductCategoryXboxOne: return "Xbox Controller"
        case "", GCProductCategoryHID, GCProductCategoryMFi:
            return vendor.isEmpty ? "Controller" : vendor
        default: return category  // DualSense, DualShock 4, Switch Pro Controller, …
        }
    }

    /// 0…1, when the controller reports its battery.
    static func battery(of controller: GCController) -> Float? {
        guard let battery = controller.battery, battery.batteryState != .unknown else { return nil }
        return battery.batteryLevel
    }

    init() {
        let center = NotificationCenter.default
        for name in [
            Notification.Name.GCControllerDidBecomeCurrent, .GCControllerDidConnect,
            .GCControllerDidDisconnect,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    // the one going away may still be listed while its notification runs; its identity crosses over
                    let gone =
                        name == .GCControllerDidDisconnect
                        ? (note.object as AnyObject?).map(ObjectIdentifier.init) : nil
                    MainActor.assumeIsolated {
                        self?.connected(GCController.controllers(), gone: gone)
                    }
                })
        }
        connected(GCController.controllers())
    }

    /// The symbol the controller last used prints on a button (Ⓐ, ✕, …), for on-screen hints.
    public func symbol(for command: Command) -> String? {
        if !sample.isEmpty {
            return switch command {
            case .confirm: "a.circle"
            case .back: "b.circle"
            case .menu: "line.3.horizontal.circle"
            default: "dpad"
            }
        }
        guard let pad = (current ?? controllers.first)?.extendedGamepad else { return nil }
        return switch command {
        case .confirm: pad.buttonA.sfSymbolsName
        case .back: pad.buttonB.sfSymbolsName
        case .menu: pad.buttonMenu.sfSymbolsName
        default: pad.dpad.sfSymbolsName
        }
    }

    /// Takes in the controllers GameController lists now: handlers on the new ones, the gone ones let go.
    private func connected(_ all: [GCController], gone: ObjectIdentifier? = nil) {
        let now = all.filter { $0.extendedGamepad != nil && ObjectIdentifier($0) != gone }
        for old in controllers where !now.contains(where: { $0 === old }) {
            stopRepeat(ObjectIdentifier(old))
            if current === old { current = nil }
        }
        for controller in now where !controllers.contains(where: { $0 === controller }) {
            attach(controller)
        }
        controllers = now
        lightPlayers()
    }

    /// Each controller's player lights (Joy-Con, Pro Controller, DualSense, …) show the player it is in a game: 1–4,
    /// none past the fourth (GameController has four).
    private func lightPlayers() {
        let numbers = Self.numbers(
            count: controllers.count, merged: merged, keyboardOwnPlayer: keyboardOwnPlayer)
        for (controller, number) in zip(controllers, numbers) {
            controller.playerIndex =
                number.flatMap { GCControllerPlayerIndex(rawValue: $0 - 1) } ?? .indexUnset
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let id = ObjectIdentifier(controller)
        // handlers run on the main queue (GameController's default handler queue)
        func press(_ command: Command) -> GCControllerButtonValueChangedHandler {
            { [weak self, weak controller] _, _, pressed in
                MainActor.assumeIsolated {
                    guard pressed else { return }
                    self?.current = controller
                    self?.send(command)
                }
            }
        }
        func direction(_ command: Command) -> GCControllerButtonValueChangedHandler {
            { [weak self, weak controller] _, _, pressed in
                MainActor.assumeIsolated {
                    if pressed { self?.current = controller }
                    self?.hold(command, pressed, on: id)
                }
            }
        }
        pad.buttonA.pressedChangedHandler = press(.confirm)
        pad.buttonB.pressedChangedHandler = press(.back)
        pad.buttonMenu.pressedChangedHandler = press(.menu)
        pad.dpad.left.pressedChangedHandler = direction(.left)
        pad.dpad.right.pressedChangedHandler = direction(.right)
        pad.dpad.up.pressedChangedHandler = direction(.up)
        pad.dpad.down.pressedChangedHandler = direction(.down)
        pad.leftThumbstick.valueChangedHandler = { [weak self, weak controller] _, x, y in
            MainActor.assumeIsolated { self?.stick(x: x, y: y, on: id, controller: controller) }
        }
    }

    /// The stick as a D-pad: past half way it presses the nearest direction, back near the middle it lets go. Each
    /// controller's own: a resting stick on one doesn't let go of a direction another holds.
    private func stick(x: Float, y: Float, on id: ObjectIdentifier, controller: GCController?) {
        let command: Command? =
            max(abs(x), abs(y)) < 0.5
            ? nil
            : abs(x) > abs(y)
                ? (x < 0 ? .left : .right)
                : (y > 0 ? .up : .down)
        guard command != held[id] else { return }
        if let previous = held[id] { hold(previous, false, on: id) }
        if let command {
            current = controller
            hold(command, true, on: id)
        }
    }

    /// A direction moves once, then again and again while held, as a keyboard repeats.
    private func hold(_ command: Command, _ pressed: Bool, on id: ObjectIdentifier) {
        guard pressed else {
            if held[id] == command { stopRepeat(id) }
            return
        }
        stopRepeat(id)
        held[id] = command
        send(command)
        repeaters[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                self?.send(command)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func stopRepeat(_ id: ObjectIdentifier) {
        repeaters[id]?.cancel()
        repeaters[id] = nil
        held[id] = nil
    }

    private func send(_ command: Command) {
        guard NSApp?.isActive != false else { return }
        onCommand?(command)
    }
}
