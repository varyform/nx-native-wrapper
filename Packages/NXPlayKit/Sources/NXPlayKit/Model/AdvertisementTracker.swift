import Foundation

/// When to give up waiting for Bonjour to confirm the service and register it again: 10 s after the first
/// registration, then 20, 40, 80, 160, and every 5 minutes after. A confirmation resets it; a service Bonjour
/// withdraws (the network went away) is waited for again from where it was.
struct AdvertisementTracker: Equatable {
    enum Action: Equatable {
        /// Nothing changes: a withdrawal of a service that wasn't confirmed.
        case unchanged
        /// Bonjour confirmed: stop waiting.
        case confirmed
        /// Give Bonjour this long, then call `timedOut`.
        case wait(Duration)
    }

    enum Timeout: Equatable {
        case restart
        case ignore
    }

    private(set) var state = RemoteServer.Advertisement.off
    private(set) var attempt = 0

    static func pause(attempt: Int) -> Duration {
        .seconds(min(10 << min(max(attempt - 1, 0), 5), 300))
    }

    /// Listening again after failures in a row: 5 s, 10, 20, 40, then every minute.
    static func pause(afterFailures failures: Int) -> Duration {
        .seconds(min(5 << min(max(failures - 1, 0), 4), 60))
    }

    mutating func started() -> Action {
        attempt += 1
        state = .registering(attempt: attempt)
        return .wait(Self.pause(attempt: attempt))
    }

    mutating func added(name: String) -> Action {
        state = .advertised(name: name)
        attempt = 0
        return .confirmed
    }

    mutating func removed() -> Action {
        guard case .advertised = state else { return .unchanged }
        attempt = max(attempt, 1)
        state = .registering(attempt: attempt)
        return .wait(Self.pause(attempt: attempt))
    }

    /// The wait ran out: register again while Bonjour still hasn't confirmed.
    func timedOut() -> Timeout {
        if case .registering = state { return .restart }
        return .ignore
    }

    mutating func stopped() {
        state = .off
        attempt = 0
    }
}
