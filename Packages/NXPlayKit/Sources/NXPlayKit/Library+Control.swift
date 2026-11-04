import AppKit
import Foundation

/// The local control API (Control/): scripts and agents on this Mac drive NX Play through the commands in
/// Library+ControlCommands.swift, on the loopback interface only, with a token of its own in a file only this user can
/// read. Off unless asked for at launch (ControlEndpointFile.isEnabled); never in screenshot mode.
extension Library {
    /// The API's jobs and events, while it runs.
    var controlHub: ControlHub? { controlAPI?.hub }

    /// Starts the API when it's turned on for this launch.
    func applyControl(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard !isScreenshot, controlAPI == nil else { return }
        let endpoint = ControlEndpointFile.standard(environment: environment)
        guard ControlEndpointFile.isEnabled(environment: environment, arguments: arguments, enabledFile: endpoint.enabledFile)
        else { return }
        startControl(endpoint: endpoint, port: ControlEndpointFile.port(environment: environment))
    }

    /// Starts the API with its descriptor in `endpoint` (tests give a folder of their own and port 0).
    @discardableResult
    func startControl(endpoint: ControlEndpointFile, port: UInt16 = 0) -> ControlAPI {
        let api = ControlAPI(library: self, endpoint: endpoint)
        controlAPI = api
        api.start(port: port)
        return api
    }

    /// Stops the API and removes its descriptor (NX Play quitting, or a test ending).
    func stopControl() {
        controlAPI?.stop()
        controlAPI = nil
    }

    /// Why the API isn't running when it was asked for (the port taken, the folder not private).
    public var controlProblem: String? { controlAPI?.problem }

    /// Asks RootView to open a window, and waits a moment for it to say it opened this very request. False when no
    /// RootView answered it in time (the main window is closed): the request is then withdrawn, so it can't open later
    /// behind a call that said it didn't. NX Play is brought forward either way. Requests queue: several calls at once
    /// are each opened and each answered for itself, never one acknowledgement standing for another.
    func controlOpen(_ window: ControlWindow) async -> Bool {
        if !isScreenshot { NSApp?.activate() }
        controlWindowSerial += 1
        let serial = controlWindowSerial
        windowRequests.append(ControlWindowRequest(window: window, serial: serial))
        if let hub = controlHub {
            await hub.wait(timeout: windowOpenTimeout) { self.windowRequestsOpened.contains(serial) }
        }
        let opened = windowRequestsOpened.remove(serial) != nil
        if !opened { windowRequests.removeAll { $0.serial == serial } }
        return opened
    }

    /// RootView's part: opens every waiting request, oldest first, with `open` (only a view can), and answers each.
    /// Called when the requests change and when the main window appears.
    public func openRequestedWindows(_ open: (ControlWindow) -> Void) {
        let pending = windowRequests
        guard !pending.isEmpty else { return }
        for request in pending {
            open(request.window)
            windowRequestsOpened.insert(request.serial)
        }
        let done = Set(pending.map(\.serial))
        windowRequests.removeAll { done.contains($0.serial) }
        controlHub?.notify()
    }
}
