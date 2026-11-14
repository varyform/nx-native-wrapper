import Foundation

/// Where the camera's codes go (QRScannerView): the scanner's side, on the main actor. The capture queue holds it
/// from the start and only hands codes to it (`deliver`), so the queue touches nothing that changes. The callback and
/// whether the scanner is still open live on the main actor, so once `close` has run, codes still on their way are
/// dropped there, and none arrives after the scanner has gone.
@MainActor final class QRCodeSink {
    private var onCode: ((String) -> Void)?
    private(set) var isClosed = false

    init() {}

    /// Starts passing codes to `onCode`; nothing after `close`.
    func open(_ onCode: @escaping (String) -> Void) {
        guard !isClosed else { return }
        self.onCode = onCode
    }

    /// For good: codes delivered before, still waiting for the main actor, go nowhere.
    func close() {
        isClosed = true
        onCode = nil
    }

    /// From any queue: the code reaches `onCode` on the main actor, if the scanner is open by then.
    nonisolated func deliver(_ text: String) {
        Task { @MainActor in self.receive(text) }
    }

    private func receive(_ text: String) {
        guard !isClosed else { return }
        onCode?(text)
    }
}
