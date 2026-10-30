import SwiftUI

/// Game › Remove Game…: what goes and what stays, the saves kept unless the player says why they may go, and one of
/// a few phrases, picked at random, typed to confirm.
struct RemoveGameView: View {
    let game: Game
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var removesSaves = false
    @State private var reason: Reason?
    @State private var typed = ""
    @State private var phrase = GameRemoval.phrases.randomElement() ?? GameRemoval.phrases[0]
    @State private var size: Int64?
    @State private var removing = false
    @State private var failures: [String] = []

    /// Why the saves may go: asked, so no one loses them by ticking a box.
    enum Reason: Hashable { case backedUp, notNeeded }

    var body: some View {
        let removal = GameRemoval(game: game, removesSaves: removesSaves)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GameIcon(url: library.icon(for: game)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove \(game.name)?").font(.title2.bold())
                    Text(
                        size.map { "Frees \(Self.bytes($0)), deleted for good" }
                            ?? "Measuring\u{2026}"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            what(removal)
            if !removal.saves.isEmpty { saves(removal) }
            VStack(alignment: .leading, spacing: 6) {
                Text("Type \u{201C}\(phrase)\u{201D} to confirm").font(.callout)
                TextField(phrase, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { remove() }
            }
            if !failures.isEmpty {
                Label(
                    "Not everything went: " + failures.joined(separator: "; "),
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
                .font(.callout)
            }
            HStack {
                if removing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove Game", role: .destructive) { remove() }
                    .disabled(!canRemove)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: removesSaves) {
            size = nil
            size = await Task.detached { removal.size() }.value
        }
    }

    private var canRemove: Bool {
        !removing && library.canRemove(game)
            && Cleanup.normalized(typed) == Cleanup.normalized(phrase)
            && (!removesSaves || reason != nil)
    }

    /// What goes, by kind, and what else in the folder stays.
    private func what(_ removal: GameRemoval) -> some View {
        let names = removal.items.map(\.lastPathComponent)
        let count = { (test: (String) -> Bool) in names.filter(test).count }
        let packages = count {
            GameScanner.packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        let rows: [(String, Bool)] = [
            ("\(packages) game file\(packages == 1 ? "" : "s") (NSP, NSZ, XCI, XCZ)", packages > 0),
            ("The build: extracted game, rewritten code, shaders", game.buildFolder != nil),
            ("The Mac app", names.contains { $0.hasSuffix(".app") }),
            ("IPAs", names.contains { $0.lowercased().hasSuffix(".ipa") }),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.filter(\.1), id: \.0) { row in
                Label(row.0, systemImage: "minus.circle").foregroundStyle(.primary)
            }
            if !removal.others.isEmpty {
                Label(
                    "Stays in the folder: "
                        + removal.others.map(\.lastPathComponent).joined(separator: ", "),
                    systemImage: "folder"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func saves(_ removal: GameRemoval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Also remove its saves", isOn: $removesSaves)
            if removesSaves {
                Picker("Why", selection: $reason) {
                    Text("I have a backup of them").tag(Reason?.some(.backedUp))
                    Text("I don't need them").tag(Reason?.some(.notNeeded))
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(
                    removal.appData == nil
                        ? "The saves are deleted with the rest."
                        : "The saves are deleted with the rest, and so is the Mac app's own save."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "Its saves stay in the folder (\(game.buildFolder?.lastPathComponent ?? "the build")/run). Put the game files back in it and the game plays on from them."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func remove() {
        guard canRemove else { return }
        removing = true
        Task {
            failures = await library.remove(game, removingSaves: removesSaves)
            removing = false
            if failures.isEmpty { dismiss() }
        }
    }

    static func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
