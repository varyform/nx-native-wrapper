import Foundation

/// nxplay's question before a play, shown as a sheet: Console Mode answers it with the controller, so the highlighted
/// row lives here.
public struct UpdatePrompt: Identifiable {
    public enum Row: CaseIterable, Sendable {
        case update, current
    }

    public let job: Job
    public let ask: UpdateAsk
    public var focus: Row = .update
    public var id: UUID { job.id }
}

/// Ask before updating (issue #7): when nxnative has new code for a game built with older code, nxplay says what
/// the update brings and waits for the answer: update first, play the current build, or don't play.
extension Library {
    /// The next play waiting for an answer, one sheet at a time.
    func presentNextAsk() {
        guard updatePrompt == nil,
            let job = jobs.values.first(where: { $0.ask != nil && $0.status.isActive }),
            let ask = job.ask
        else { return }
        updatePrompt = UpdatePrompt(job: job, ask: ask)
        selection = job.game.id
    }

    public func answerUpdate(_ answer: UpdateAnswer) {
        guard let prompt = updatePrompt else { return }
        updatePrompt = nil
        prompt.job.answer(answer)
        presentNextAsk()
    }

    /// The controller: left and right, or up and down, choose; A answers; B doesn't play.
    func handleUpdatePrompt(_ command: Gamepad.Command) {
        guard var prompt = updatePrompt else { return }
        switch command {
        case .up, .down, .left, .right:
            prompt.focus = prompt.focus == .update ? .current : .update
        case .confirm:
            return answerUpdate(prompt.focus == .update ? .update : .current)
        case .back: return answerUpdate(.cancel)
        case .menu, .info: break
        }
        updatePrompt = prompt
    }
}
