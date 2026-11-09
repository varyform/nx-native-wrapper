import Foundation
import os

/// A play asking which save to keep: with cloud saves on, the cloud's save and this Mac's both changed since they were
/// last the same (played on two devices without a sync in between, or this Mac's first sync with a save of its
/// own). The one not chosen is kept in the save's backups. Console Mode answers it with the controller.
public struct CloudSaveQuestion: Identifiable, Sendable {
    public enum Row: CaseIterable, Sendable {
        case here, cloud, cancel
    }

    public let game: Game
    /// The Mac app's own save when Play uses it (Library+AppSave.swift), else the build's.
    public let appSave: URL?
    public let here: CloudSave.Snapshot
    public let cloud: CloudSave.Snapshot
    public var focus: Row
    public var id: Game.ID { game.id }

    public var cloudIsNewer: Bool { (cloud.saved ?? .distantPast) > (here.saved ?? .distantPast) }

    init(game: Game, appSave: URL?, here: CloudSave.Snapshot, cloud: CloudSave.Snapshot) {
        self.game = game
        self.appSave = appSave
        self.here = here
        self.cloud = cloud
        focus = .here
        if cloudIsNewer { focus = .cloud }
    }
}

/// nxnative takes the newer of two saves that both changed, unless a front end asks the player
/// (DM_SAVE_SYNC_CHOICE). NX Play asks: it compares the two before the play, and with cloud saves on every play says
/// so, so the host never picks on its own; one that started without a choice keeps this Mac's save and sends nothing,
/// and the next Play asks.
extension Library {
    /// A play whose save is settled: straight on, or after the cloud's save is compared with it.
    func playChecked(_ game: Game, appSave: URL?) {
        let target = Self.cloudSaveTarget(cloudSaves)
        guard let id = game.titleID,
            let cloud = CloudSave.file(
                target: target, titleID: id, home: FileManager.default.homeDirectoryForCurrentUser),
            let save = appSave ?? game.buildFolder?.appending(path: "run/save", directoryHint: .isDirectory)
        else { return run(.play, game, appSave: appSave) }
        guard checkingCloudSaves.insert(game.id).inserted else { return }
        Task {
            let check = await Self.checkCloud(save: save, cloud: cloud, titleID: id)
            checkingCloudSaves.remove(game.id)
            switch check {
            case .nothingToChoose:
                run(.play, game, appSave: appSave)
            case .bothChanged(let here, let remote):
                cloudSaveQuestion = CloudSaveQuestion(game: game, appSave: appSave, here: here, cloud: remote)
            }
        }
    }

    /// The player's answer; nil cancels the play.
    public func answerCloudSaveQuestion(_ choice: CloudSaveQuestion.Row?) {
        guard let question = cloudSaveQuestion else { return }
        cloudSaveQuestion = nil
        let hash = question.cloud.hash
        switch choice {
        case .here: run(.play, question.game, appSave: question.appSave, cloudChoice: .here(hash))
        case .cloud: run(.play, question.game, appSave: question.appSave, cloudChoice: .cloud(hash))
        case .cancel, nil: break
        }
    }

    /// The controller: up and down move through the rows, A answers, B doesn't play.
    func handleCloudSaveQuestion(_ command: Gamepad.Command) {
        guard var question = cloudSaveQuestion else { return }
        let rows = CloudSaveQuestion.Row.allCases
        let index = rows.firstIndex(of: question.focus) ?? 0
        switch command {
        case .up, .left: question.focus = rows[max(0, index - 1)]
        case .down, .right: question.focus = rows[min(rows.count - 1, index + 1)]
        case .confirm: return answerCloudSaveQuestion(question.focus)
        case .back: return answerCloudSaveQuestion(nil)
        case .menu, .info: break
        }
        cloudSaveQuestion = question
    }

    /// Off the main thread, as reading a file iCloud keeps only listed downloads it first. A cloud that doesn't answer
    /// within the host's own wait (FETCH_MS) leaves the choice to the host, which keeps both saves when both changed.
    nonisolated static func checkCloud(save: URL, cloud: URL, titleID: String, timeout: TimeInterval = 10)
        async -> CloudSave.Check
    {
        let answered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (CloudSave.Check) -> Void = { check in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: check) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(CloudSave.check(save: save, cloud: cloud, titleID: titleID))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.nothingToChoose) }
        }
    }
}
