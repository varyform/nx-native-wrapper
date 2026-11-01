import Foundation

/// A play asking which save to use: the game's Mac app has a save of its own that differs from NX Play's. The other
/// save stays as it is. Console Mode answers it with the controller, so the highlighted row lives here.
public struct SaveQuestion: Identifiable, Sendable {
    public enum Row: CaseIterable, Sendable {
        case nxplay, app, newer, remember
    }

    public let game: Game
    public let appSave: AppSave
    public var focus: Row = .newer
    public var remember = false
    public var id: Game.ID { game.id }
}

/// Play with the Mac app's own save, or NX Play's (issue #8): asked while the two differ, unless the player said not
/// to ask again for the game.
extension Library {
    public func play(_ game: Game) {
        guard !isBusy(game) else { return }
        guard let appSave = AppSave(game: game) else { return run(.play, game) }
        if let choice = saveChoice(for: game) {
            run(.play, game, appSave: appSave.usesApp(choice) ? appSave.folder : nil)
        } else if appSave.differs {
            saveQuestion = SaveQuestion(game: game, appSave: appSave)
        } else {
            run(.play, game)
        }
    }

    /// The choice kept for the game with "Don't ask again".
    public func saveChoice(for game: Game) -> SaveChoice? {
        game.titleID.flatMap { saveChoices[$0.uppercased()] }
    }

    /// Game Settings › Ask Again.
    public func forgetSaveChoice(for game: Game) {
        guard let id = game.titleID?.uppercased() else { return }
        saveChoices[id] = nil
    }

    /// The player's answer; nil cancels the play.
    public func answerSaveQuestion(_ choice: SaveChoice?) {
        guard let question = saveQuestion else { return }
        saveQuestion = nil
        guard let choice else { return }
        if question.remember, let id = question.game.titleID?.uppercased() {
            saveChoices[id] = choice
        }
        run(
            .play, question.game,
            appSave: question.appSave.usesApp(choice) ? question.appSave.folder : nil)
    }

    /// The controller: up and down move through the rows, A picks the save or ticks "Don't ask again", B cancels.
    func handleSaveQuestion(_ command: Gamepad.Command) {
        guard var question = saveQuestion else { return }
        let rows = SaveQuestion.Row.allCases
        let index = rows.firstIndex(of: question.focus) ?? 0
        switch command {
        case .up, .left: question.focus = rows[max(0, index - 1)]
        case .down, .right: question.focus = rows[min(rows.count - 1, index + 1)]
        case .confirm:
            switch question.focus {
            case .nxplay: return answerSaveQuestion(.nxplay)
            case .app: return answerSaveQuestion(.app)
            case .newer: return answerSaveQuestion(.newer)
            case .remember: question.remember.toggle()
            }
        case .back: return answerSaveQuestion(nil)
        case .menu, .info: break
        }
        saveQuestion = question
    }
}
