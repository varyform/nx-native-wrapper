import SwiftUI

/// Game Settings' mods: each folder of the game's Mods folder, on or off, dragged into the order they load in.
struct GameModsSection: View {
    let game: Game
    @Environment(Library.self) private var library

    var body: some View {
        let mods = library.gameMods[game.id] ?? []
        Section {
            ForEach(Array(mods.enumerated()), id: \.element.id) { index, mod in
                ModRow(
                    mod: mod, files: library.modFiles[game.id]?[mod.name],
                    isOn: Binding(get: { mod.isOn }, set: { library.setMod(mod.name, on: $0, for: game) })
                )
                .draggable(mod.name)
                .dropDestination(for: String.self) { names, _ in
                    guard let name = names.first else { return false }
                    library.moveMod(name, before: mod.name, for: game)
                    return true
                }
                .contextMenu {
                    Button("Move Up") { library.moveMod(mod.name, before: mods[max(0, index - 1)].name, for: game) }
                        .disabled(index == 0)
                    Button("Move Down") {
                        library.moveMod(mod.name, before: index + 2 < mods.count ? mods[index + 2].name : nil, for: game)
                    }
                    .disabled(index == mods.count - 1)
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mod.folder]) }
                }
            }
            if mods.isEmpty {
                Text("No mods yet. Put each one in a folder of its own in the game\u{2019}s Mods folder.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Mods")
                Spacer()
                Button("Open Mods Folder") { openFolder() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } footer: {
            Text(
                "Each mod is a folder holding the romfs folder of the game\u{2019}s files it changes, as mods are shared (an atmosphere/contents/<title ID> folder around it is fine). Drag them into order: when two change the same file, the higher one wins. Changes apply the next time the game starts, on this Mac: an iPhone app or a device install doesn\u{2019}t get them. A mod that changes the game\u{2019}s code (exefs) can\u{2019}t work, as nxnative builds the game\u{2019}s code beforehand, and new shaders may not draw for the same reason."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        // while the window is open, a mod added, removed or changed in Finder shows at once
        .task(id: game.id) {
            await library.loadMods(for: game)
            for await _ in library.modsChanges(for: game) { await library.loadMods(for: game) }
        }
    }

    private func openFolder() {
        let folder = library.modsFolder(for: game)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct ModRow: View {
    let mod: GameMod
    let files: GameModFiles?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(mod.problem == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(mod.problem != nil)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        switch mod.problem {
        case .noRomFS:
            return mod.hasExeFS
                ? "Only code changes (exefs), which nxnative can\u{2019}t use" : "No romfs folder in it"
        case .colonInPath: return "Its folder\u{2019}s path has a colon, which nxnative can\u{2019}t take: rename it"
        case nil: break
        }
        var parts: [String] = []
        if let files {
            parts.append(files.count == 1 ? "1 file" : "\(files.count) files")
            for (name, count) in files.covered.sorted(by: { $0.key < $1.key }) {
                parts.append("\(count) from \(name), above")
            }
        }
        if mod.hasExeFS { parts.append("its code changes (exefs) aren\u{2019}t used") }
        if let other = mod.otherTitle { parts.append("made for \(other), another release") }
        return parts.isEmpty ? "Counting files\u{2026}" : parts.joined(separator: " \u{00B7} ")
    }
}
