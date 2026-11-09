import SwiftUI

/// Settings › General › Games Folders: the folders the library is made of (Library+Folders.swift).
struct GamesFoldersSection: View {
    @Environment(Library.self) private var library

    var body: some View {
        Section {
            if library.roots.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(library.roots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((root.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !library.isConnected(root) {
                            Text("Not connected: its games show again once it is")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { library.removeRoot(root) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Take this folder\u{2019}s games out of the library: nothing on disk changes")
                }
            }
            Button("Add Folder…") { library.addRoot() }
        } header: {
            Text("Games Folders")
        } footer: {
            Footer(
                "Each is a folder with one subfolder per game, or a game\u{2019}s own folder. Their games show as one library. Builds and saves stay in each game\u{2019}s folder, so a game plays on from its build whichever way it was added. A folder can\u{2019}t be inside another one."
            )
        }
    }
}
