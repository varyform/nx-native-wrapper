import Foundation

/// nxplay's question before a play, shown as a sheet: Console Mode answers it with the controller, so the highlighted
/// row lives here.
public struct UpdatePrompt: Identifiable {
    public enum Row: CaseIterable, Sendable {
        case update, current, cancel
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

    /// The controller: up and down, or left and right, move through the rows; A answers; B doesn't play.
    func handleUpdatePrompt(_ command: Gamepad.Command) {
        guard var prompt = updatePrompt else { return }
        let rows = UpdatePrompt.Row.allCases
        let index = rows.firstIndex(of: prompt.focus) ?? 0
        switch command {
        case .up, .left: prompt.focus = rows[max(0, index - 1)]
        case .down, .right: prompt.focus = rows[min(rows.count - 1, index + 1)]
        case .confirm:
            let answer: UpdateAnswer =
                switch prompt.focus {
                case .update: .update
                case .current: .current
                case .cancel: .cancel
                }
            return answerUpdate(answer)
        case .back: return answerUpdate(.cancel)
        case .menu, .info: break
        }
        updatePrompt = prompt
    }
}
