import SwiftUI

/// Tools › Free Up Space: every removable file and folder per game with its size, selectable one by one, per
/// game or per kind, and deleted only after a typed confirmation.
public struct CleanupView: View {
    public static let windowID = "free-up-space"

    @Environment(Library.self) private var library
    @State private var cleanup = Cleanup(cache: SizeCache())

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
                        : "No game files, builds, IPAs or Xcode builds in \(library.root?.lastPathComponent ?? "")."
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
                        .disabled(
                            files.allSatisfy {
                                !cleanup.isAvailable($0) && !cleanup.selection.contains($0.url)
                            })
                    Text(kind.title).fontWeight(.medium)
                    Text(
                        bytes(cleanup.size(kind)) + (files.contains(where: \.measuring) ? "…" : "")
                    )
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
                        FileRow(
                            file: file, isOn: cleanup.selection.contains(file.url),
                            unavailable: file.blocked ?? cleanup.conflict(file)
                        ) {
                            cleanup.toggle(file)
                        }
                    }
                } header: {
                    GroupHeader(
                        group: group, selected: cleanup.isSelected(group),
                        disabled: group.files.allSatisfy {
                            !cleanup.isAvailable($0) && !cleanup.selection.contains($0.url)
                        }
                    ) {
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
                    "\(bytes(cleanup.totalSize))\(cleanup.isMeasuring ? "… (measuring)" : "") in \(cleanup.groups.count) game\(cleanup.groups.count == 1 ? "" : "s")"
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
        let kinds = Set(cleanup.selectedFiles.map(\.kind))
        var text = "Deleted for good, not moved to the Trash."
        if kinds.contains(.gameFiles) {
            text +=
                " Without its game files a game can't be rebuilt: it keeps its current build when nxnative updates, and Install on Device and Build IPA need the files back. If this folder holds your only copy of a game, keep a backup elsewhere."
        }
        if kinds.contains(.builds) {
            text +=
                " A game without its build is built again from its game files the next time you play it, which takes as long as its first build. Its saves stay."
        }
        return text
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
        case .builds: "Builds"
        case .ipas: "IPAs"
        case .xcodeBuilds: "Xcode builds"
        case .macApps: "Mac apps"
        }
    }

    var note: LocalizedStringKey {
        switch self {
        case .gameFiles:
            "NSP, NSZ, XCI, XCZ of games built for the Mac: they keep playing, but can't be rebuilt."
        case .builds: "Play builds them again from the game files; saves stay."
        case .ipas: "Build IPA makes them again."
        case .xcodeBuilds: "Install on Device makes them again; the next install takes longer."
        case .macApps:
            "Make Mac App makes them again. Their own saves, in ~/Library/Application Support/nxnative, stay."
        }
    }
}

/// The Tools menu (openWindow needs a view's environment).
public struct ToolsMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        Button("Update All Builds…") { library.showsUpdateAll = true }
            .disabled(library.updatableGames.isEmpty)
        Button("Free Up Space…") { openWindow(id: CleanupView.windowID) }
    }
}
