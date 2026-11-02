import SwiftUI

/// Play's question when the game's Mac app has a save of its own that differs from NX Play's: which one the game
/// plays on from. Nothing is copied or deleted; the other save stays as it is. In Console Mode the controller moves
/// the highlight (Library.handleSaveQuestion).
struct SaveChoiceView: View {
    let question: SaveQuestion
    @Environment(Library.self) private var library

    var body: some View {
        let save = question.appSave
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GameIcon(url: library.icon(for: question.game)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which save should \(question.game.name) use?").font(.title2.bold())
                    Text(
                        "Its Mac app, opened from Finder, keeps a save of its own, and it differs from NX Play\u{2019}s. The other one stays as it is."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 8) {
                row(
                    .nxplay, "NX Play\u{2019}s Save", detail: saved(save.nxplaySaved),
                    newer: !save.appIsNewer && save.nxplaySaved != nil)
                row(.app, "The Mac App\u{2019}s Save", detail: saved(save.appSaved), newer: save.appIsNewer)
                row(
                    .newer, "The Newer One",
                    detail: "Whichever was saved last when the game starts", newer: false)
            }
            Toggle(isOn: remember) {
                Text("Don\u{2019}t ask again for this game")
                Text("Game Settings can ask again.")
            }
            .padding(6)
            .overlay(highlight(.remember))
            DontPlayRow(highlighted: library.saveQuestion?.focus == .cancel) {
                library.answerSaveQuestion(nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(_ row: SaveQuestion.Row, _ title: String, detail: String, newer: Bool)
        -> some View
    {
        Button {
            library.answerSaveQuestion(choice(row))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if newer {
                    Text("Newer").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(highlight(row))
        .keyboardShortcut(row == .newer ? .defaultAction : nil)
    }

    /// The controller's row, in Console Mode.
    private func highlight(_ row: SaveQuestion.Row) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.tint, lineWidth: 2)
            .opacity(library.consoleMode && library.saveQuestion?.focus == row ? 1 : 0)
    }

    private func choice(_ row: SaveQuestion.Row) -> SaveChoice? {
        switch row {
        case .nxplay: .nxplay
        case .app: .app
        case .newer: .newer
        case .remember, .cancel: nil
        }
    }

    private func saved(_ date: Date?) -> String {
        date.map { "Last saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Empty"
    }

    private var remember: Binding<Bool> {
        Binding(
            get: { library.saveQuestion?.remember ?? false },
            set: { library.saveQuestion?.remember = $0 })
    }
}
