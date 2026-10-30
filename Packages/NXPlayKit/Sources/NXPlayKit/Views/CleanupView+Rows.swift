import SwiftUI

/// A checkbox with AppKit's mixed state (nil): a dash when some, not all, are selected.
struct Checkbox: View {
    let state: Bool?
    let toggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { state == true }, set: { _ in toggle() })) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .overlay {
                if state == nil {
                    RoundedRectangle(cornerRadius: 1).fill(.primary).frame(width: 8, height: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct GroupHeader: View {
    let group: CleanupGroup
    let selected: Bool?
    let disabled: Bool
    let toggle: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: selected, toggle: toggle)
                .disabled(disabled)
            GameIcon(url: library.icon(for: group.game)).frame(width: 28, height: 28)
            Text(group.game.name).font(.headline).foregroundStyle(.primary)
            Spacer()
            Text(
                ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file)
                    + (group.files.contains(where: \.measuring) ? "…" : "")
            )
            .font(.headline.monospacedDigit())
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

struct FileRow: View {
    let file: CleanupFile
    let isOn: Bool
    /// Why it can't be picked now: blocked, or in conflict with what's picked.
    let unavailable: String?
    let toggle: () -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if let caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(unavailable != nil && !isOn)
            Spacer()
            Badge(text: file.kind.title, color: unavailable == nil ? .secondary : .gray)
            Group {
                // a big folder takes a while: its last size with a spinner, or the spinner alone
                if file.measuring {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        if file.size > 0 {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: file.size, countStyle: .file))
                        }
                    }
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                }
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.leading, 26)
        .help(file.url.path)
    }

    private var title: String {
        switch file.role {
        case .xcodeBuild: "Xcode build (for Install on Device)"
        case .build: "Build (\(file.url.lastPathComponent))"
        default: file.url.lastPathComponent
        }
    }

    /// Why it can't go, or where an extra copy comes from.
    private var caption: String? {
        if let unavailable, !isOn { return unavailable }
        let build = file.url.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent
        return switch file.role {
        case .converted: "Converted from NSZ by the build, in \(build)/nsp"
        case .build: "The extracted and built game; its saves stay"
        case .xcodeBuild:
            "\(file.url.deletingLastPathComponent().lastPathComponent)/xcode-derived-data: a full copy of the game"
        case .macApp: "Made of APFS clones of the build: the size is what only the app takes"
        default: nil
        }
    }
}
