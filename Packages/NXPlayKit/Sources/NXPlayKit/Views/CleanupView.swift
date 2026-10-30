import SwiftUI

/// Tools › Free Up Space: every removable file and folder per game with its size, selectable one by one, per
/// game or per kind, and deleted only after a typed confirmation.
public struct CleanupView: View {
    public static let windowID = "free-up-space"

    @Environment(Library.self) private var library
    @State private var cleanup = Cleanup()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Free Up Space").font(.title2.bold())
            if cleanup.groups.isEmpty {
                empty
            } else {
                kinds
                list
                footer
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
        .task { await rescan() }
        .onChange(of: library.games) { Task { await rescan() } }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            library.refresh()
            Task { await rescan() }
        }
    }

    @ViewBuilder private var empty: some View {
        if cleanup.phase == .scanning {
            ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Nothing to Remove", systemImage: "externaldrive",
                description: Text(
                    library.root == nil
                        ? "Choose a games folder first."
                        : "No game files, IPAs or Xcode builds in \(library.root?.lastPathComponent ?? "")."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One row per kind: select it everywhere, its total, and what deleting it costs.
    private var kinds: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(CleanupKind.allCases) { kind in
                let files = cleanup.files(kind)
                GridRow {
                    Checkbox(state: cleanup.isSelected(kind)) { cleanup.toggle(kind) }
                        .disabled(files.allSatisfy { $0.blocked != nil })
                    Text(kind.title).fontWeight(.medium)
                    Text(bytes(cleanup.size(kind)))
                        .monospacedDigit()
                        .foregroundStyle(files.isEmpty ? .tertiary : .primary)
                        .gridColumnAlignment(.trailing)
                    Text(kind.note).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(cleanup.groups) { group in
                Section {
                    ForEach(group.files) { file in
                        FileRow(file: file, isOn: cleanup.selection.contains(file.url)) {
                            cleanup.toggle(file)
                        }
                    }
                } header: {
                    GroupHeader(group: group, selected: cleanup.isSelected(group)) {
                        cleanup.toggle(group)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected: \(bytes(cleanup.selectedSize))").fontWeight(.medium)
                Spacer()
                Text(
                    "\(bytes(cleanup.totalSize)) in \(cleanup.groups.count) game\(cleanup.groups.count == 1 ? "" : "s")"
                )
                .foregroundStyle(.secondary)
            }
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            switch cleanup.phase {
            case .done(let count, let size):
                Label(
                    "Removed \(count) item\(count == 1 ? "" : "s"), freed \(bytes(size)).",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
            HStack {
                TextField("Type “\(Cleanup.phrase)” to confirm", text: $cleanup.confirmation)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit(delete)
                if cleanup.phase == .deleting || cleanup.phase == .scanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(role: .destructive, action: delete) {
                    Text(
                        cleanup.selection.isEmpty
                            ? "Delete" : "Delete \(bytes(cleanup.selectedSize))")
                }
                .disabled(!cleanup.canDelete)
            }
        }
    }

    /// The full caveat once game files are in the selection: they are the only thing that cannot be made again.
    private var warning: String {
        if cleanup.selectedFiles.contains(where: { $0.kind == .gameFiles }) {
            return
                "Deleted for good, not moved to the Trash. Without its game files a game can't be rebuilt: it keeps its current build when nxnative updates, and Install on Device and Build IPA need the files back. If this folder holds your only copy of a game, keep a backup elsewhere."
        }
        return "Deleted for good, not moved to the Trash."
    }

    private func rescan() async {
        let busy = Set(library.games.filter(library.isBusy).map(\.id))
        await cleanup.scan(games: library.games, busy: busy)
    }

    private func delete() {
        guard cleanup.canDelete else { return }
        Task {
            await rescan()  // a game that started building meanwhile is no longer selectable
            await library.inFlight { await cleanup.delete() }
            library.refresh()
            await rescan()
        }
    }

    private func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

extension CleanupKind {
    var title: LocalizedStringKey {
        switch self {
        case .gameFiles: "Game files"
        case .ipas: "IPAs"
        case .xcodeBuilds: "Xcode builds"
        }
    }

    var note: LocalizedStringKey {
        switch self {
        case .gameFiles:
            "NSP, NSZ, XCI, XCZ of games built for the Mac: they keep playing, but can't be rebuilt."
        case .ipas: "Build IPA makes them again."
        case .xcodeBuilds: "Install on Device makes them again; the next install takes longer."
        }
    }
}

/// A checkbox with AppKit's mixed state (nil): a dash when some, not all, are selected.
private struct Checkbox: View {
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

private struct GroupHeader: View {
    let group: CleanupGroup
    let selected: Bool?
    let toggle: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: selected, toggle: toggle)
                .disabled(group.files.allSatisfy { $0.blocked != nil })
            GameIcon(url: library.icon(for: group.game)).frame(width: 28, height: 28)
            Text(group.game.name).font(.headline).foregroundStyle(.primary)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

private struct FileRow: View {
    let file: CleanupFile
    let isOn: Bool
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
            .disabled(file.blocked != nil)
            Spacer()
            Badge(text: file.kind.title, color: file.blocked == nil ? .secondary : .gray)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.leading, 26)
        .help(file.url.path)
    }

    private var title: String {
        file.role == .xcodeBuild
            ? "Xcode build (for Install on Device)" : file.url.lastPathComponent
    }

    /// Why it can't go, or where an extra copy comes from.
    private var caption: String? {
        if let blocked = file.blocked { return blocked }
        let build = file.url.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent
        return switch file.role {
        case .converted: "Converted from NSZ by the build, in \(build)/nsp"
        case .xcodeBuild:
            "\(file.url.deletingLastPathComponent().lastPathComponent)/xcode-derived-data: a full copy of the game"
        default: nil
        }
    }
}

/// The Tools menu (openWindow needs a view's environment).
public struct ToolsMenu: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("Free Up Space…") { openWindow(id: CleanupView.windowID) }
    }
}
