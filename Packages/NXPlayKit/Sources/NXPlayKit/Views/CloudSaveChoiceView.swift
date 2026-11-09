import SwiftUI

/// Play's question when the cloud's save and this Mac's both changed since they were last the same: which one the
/// game plays on from. The other is kept in the save's backups. In Console Mode the controller moves the highlight
/// (Library.handleCloudSaveQuestion).
struct CloudSaveChoiceView: View {
    let question: CloudSaveQuestion
    @Environment(Library.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GameIcon(url: library.icon(for: question.game)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which save should \(question.game.name) use?").font(.title2.bold())
                    Text(
                        "The save in your cloud saves folder and the one on this Mac both changed since they were last the same. The one you don\u{2019}t choose is kept in the save\u{2019}s backups."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 8) {
                row(
                    .here, "This Mac\u{2019}s Save", detail: saved(question.here.saved, on: ""),
                    newer: !question.cloudIsNewer)
                row(
                    .cloud, "The Cloud\u{2019}s Save",
                    detail: saved(question.cloud.saved, on: question.cloud.device),
                    newer: question.cloudIsNewer)
            }
            DontPlayRow(highlighted: focused(.cancel)) { library.answerCloudSaveQuestion(nil) }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(_ row: CloudSaveQuestion.Row, _ title: String, detail: String, newer: Bool)
        -> some View
    {
        Button {
            library.answerCloudSaveQuestion(row)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused(row) ? 1 : 0)
        )
        .keyboardShortcut(newer ? .defaultAction : nil)
    }

    /// The controller's row, in Console Mode or with a controller connected.
    private func focused(_ row: CloudSaveQuestion.Row) -> Bool {
        library.showsControllerFocus && library.cloudSaveQuestion?.focus == row
    }

    /// "Last saved 9 Nov 2026 at 14:02 on iPhone17,1": the device is the model the host records.
    private func saved(_ date: Date?, on device: String) -> String {
        let when = date.map { "Last saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Saved"
        return device.isEmpty || device == "unknown" ? when : "\(when) on \(device)"
    }
}
