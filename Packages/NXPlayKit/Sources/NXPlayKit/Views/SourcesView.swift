import AppKit
import SwiftUI

/// Tools › Sources…: the player's own repositories (Repositories.swift). The sources on the left, a source's games in
/// the middle (searchable), the chosen game's files on the right with Download; Downloads lists what's running and
/// what finished, with Cancel and Retry. A downloaded game shows up in the library like one copied in.
public struct SourcesView: View {
    public static let windowID = "sources"

    enum Pane: Hashable {
        case downloads, all
        case source(String)
    }

    @Environment(Library.self) private var library
    @State private var pane: Pane? = .all
    @State private var search = ""
    @State private var selected: EntryKey?
    @State private var adding = false
    @State private var tokenSource: RepositorySource?
    @State private var problem: String?

    public init() {}

    private var repositories: Repositories { library.repositories }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 520)
        .task { await repositories.refreshStale() }
        .sheet(isPresented: $adding) { AddSourceSheet() }
        .sheet(item: $tokenSource) { TokenSheet(source: $0) }
        .alert("Sources", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Sources

    private var sidebar: some View {
        List(selection: $pane) {
            let active = repositories.downloads.filter(\.state.isActive).count
            Label("Downloads", systemImage: "arrow.down.circle")
                .badge(active)
                .tag(Pane.downloads)
            Section("Sources") {
                if repositories.sources.count > 1 {
                    Label("All Sources", systemImage: "square.stack").tag(Pane.all)
                }
                ForEach(repositories.sources) { source in
                    SourceRow(source: source)
                        .tag(Pane.source(source.id))
                        .contextMenu {
                            Button("Refresh") { Task { await repositories.refresh(source.id) } }
                                .disabled(!source.enabled)
                            Button(source.enabled ? "Turn Off" : "Turn On") {
                                repositories.setEnabled(!source.enabled, source.id)
                                if !source.enabled { Task { await repositories.refresh(source.id) } }
                            }
                            Button("Access Token…") { tokenSource = source }
                            Divider()
                            Button("Remove Source", role: .destructive) {
                                if pane == .source(source.id) { pane = .all }
                                do { try repositories.removeSource(source.id) } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { adding = true } label: { Label("Add Source", systemImage: "plus") }
                    .help("Add a repository's catalog")
                Button {
                    Task { await repositories.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read every source's catalog again")
                .disabled(repositories.sources.isEmpty)
            }
        }
    }

    // MARK: - Games

    @ViewBuilder private var content: some View {
        switch pane {
        case .downloads: DownloadsList()
        case nil, .all: entries(source: nil)
        case .source(let id): entries(source: id)
        }
    }

    @ViewBuilder private func entries(source id: String?) -> some View {
        if repositories.sources.isEmpty {
            ContentUnavailableView {
                Label("No Sources", systemImage: "externaldrive.badge.plus")
            } description: {
                Text(
                    "A source is a catalog of your own game files on a server you run: a NAS, or any web server on your network. NX Play comes with none. Catalog/README.md shows how to make one."
                )
            } actions: {
                Button("Add Source…") { adding = true }
            }
        } else {
            let rows = repositories.entries(source: id, search: search)
            List(selection: $selected) {
                if let id, let source = repositories.source(id) { status(of: source) }
                // two sources may list the same game under the same entry id: a row is the source's entry
                ForEach(rows) { row in
                    EntryRow(source: row.source, entry: row.entry).tag(row.id)
                }
            }
            .searchable(text: $search, prompt: "Search Sources")
            .overlay {
                if rows.isEmpty, !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    @ViewBuilder private func status(of source: RepositorySource) -> some View {
        switch repositories.states[source.id] ?? .notLoaded {
        case .loading: ProgressView("Reading \(source.name)…").controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .loaded(let catalog, _) where !catalog.issues.isEmpty:
            DisclosureGroup("\(catalog.issues.count) entries left out") {
                ForEach(catalog.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        case .notLoaded where !source.enabled:
            Text("Turned off").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    // MARK: - A game

    @ViewBuilder private var detail: some View {
        if pane == .downloads {
            ContentUnavailableView(
                "Downloads", systemImage: "arrow.down.circle",
                description: Text(
                    "Downloads run one at a time. Each file is checked against its size and the SHA-256 or SHA-1 its catalog publishes before it goes into the game's folder in your games folder. Install a downloaded game from the library, as any other."
                ))
        } else if let selected, let source = repositories.source(selected.source),
            let entry = repositories.catalog(selected.source)?.entries.first(where: { $0.id == selected.entry })
        {
            EntryDetail(source: source, entry: entry).id(selected)
        } else {
            ContentUnavailableView("Choose a game", systemImage: "gamecontroller")
        }
    }
}

private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct SourceRow: View {
    @Environment(Library.self) private var library
    let source: RepositorySource

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).lineLimit(1)
                Text(source.origin?.text ?? source.url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch library.repositories.states[source.id] ?? .notLoaded {
            case .loading: ProgressView().controlSize(.mini)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
            case .loaded(let catalog, _): Text("\(catalog.entries.count)").foregroundStyle(.secondary)
            case .notLoaded:
                if !source.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
            }
        }
        .opacity(source.enabled ? 1 : 0.6)
    }
}

private struct EntryRow: View {
    @Environment(Library.self) private var library
    let source: RepositorySource
    let entry: CatalogEntry

    var body: some View {
        let repositories = library.repositories
        let present = entry.packages.allSatisfy { repositories.isPresent($0, of: entry) }
        let active = entry.packages.contains { repositories.activeJob(for: $0) != nil }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text([entry.titleID, entry.version, size(entry.totalBytes)].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if active {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint).help("Downloading")
            } else if present {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In your games folder")
            }
        }
    }
}

/// A game's facts and files: the ones not in its folder yet are ticked, and Download queues them.
private struct EntryDetail: View {
    @Environment(Library.self) private var library
    let source: RepositorySource
    let entry: CatalogEntry
    @State private var chosen: Set<String> = []
    @State private var problem: String?

    var body: some View {
        let repositories = library.repositories
        let folder = repositories.folder(for: entry)
        let available = entry.packages.filter {
            !repositories.isPresent($0, of: entry) && repositories.activeJob(for: $0) == nil
        }
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.title2.bold())
                    Text([entry.publisher, entry.version].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Title ID") { Text(entry.titleID).monospaced().textSelection(.enabled) }
                LabeledContent("Source", value: source.name)
                LabeledContent("Folder") {
                    Text(library.root.map { "\($0.lastPathComponent)/\(folder)" } ?? folder)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("Files") {
                ForEach(entry.packages) { package in
                    PackageRow(
                        entry: entry, package: package,
                        isOn: Binding(
                            get: { chosen.contains(package.id) },
                            set: { if $0 { chosen.insert(package.id) } else { chosen.remove(package.id) } }))
                }
                ForEach(entry.issues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    let picked = available.filter { chosen.contains($0.id) }
                    Text(picked.isEmpty ? "Nothing chosen" : "\(picked.count) files, \(size(picked.reduce(0) { $0 + $1.bytes }))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") {
                        do {
                            try repositories.download(
                                source: source.id, entry: entry.id, packages: Set(picked.map(\.id)))
                            chosen.subtract(picked.map(\.id))
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty || library.root == nil)
                }
            } footer: {
                Text(
                    library.root == nil
                        ? "Choose a games folder first (File › Choose Games Folder…)."
                        : "The files go into the game's folder once their size and checksum match the catalog. NX Play never replaces a file that's already there, and installing on a device stays up to you."
                            + (entry.packages.contains { $0.checksum.algorithm == .sha1 }
                                ? " SHA-1 shows a file arrived whole and is the one the catalog lists; it doesn't show who made it."
                                : "")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { chosen = Set(available.map(\.id)) }
        .alert("Can't download", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }
}

private struct PackageRow: View {
    @Environment(Library.self) private var library
    let entry: CatalogEntry
    let package: CatalogPackage
    @Binding var isOn: Bool

    var body: some View {
        let repositories = library.repositories
        let present = repositories.isPresent(package, of: entry)
        let job = repositories.activeJob(for: package)
        HStack {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.filename).lineLimit(1).truncationMode(.middle)
                    Text(
                        [package.kind.label, package.version.map { "v\($0)" } ?? "", size(package.bytes),
                         package.checksum.algorithm.label]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(present || job != nil)
            Spacer()
            if present {
                Text("In the folder").font(.caption).foregroundStyle(.green)
            } else if job != nil {
                Text("Downloading").font(.caption).foregroundStyle(.tint)
            }
        }
    }
}

extension CatalogPackage.Kind {
    var label: String {
        switch self {
        case .base: "Game"
        case .update: "Update"
        case .dlc: "DLC"
        }
    }
}

/// The downloads, newest first, each with its progress and what can be done with it.
private struct DownloadsList: View {
    @Environment(Library.self) private var library

    var body: some View {
        let downloads = library.repositories.downloads.reversed()
        if downloads.isEmpty {
            ContentUnavailableView(
                "No Downloads", systemImage: "arrow.down.circle",
                description: Text("Choose a game in a source and its files to download them."))
        } else {
            List(Array(downloads)) { job in DownloadRow(job: job) }
        }
    }
}

struct DownloadRow: View {
    @Environment(Library.self) private var library
    let job: DownloadJob
    @State private var problem: String?

    var body: some View {
        let repositories = library.repositories
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.entryName).font(.headline).lineLimit(1)
                Spacer()
                switch job.state {
                case .queued, .running, .verifying:
                    Button("Cancel") { repositories.cancel(job.id) }
                case .failed, .cancelled:
                    Button("Retry") {
                        do { try repositories.retry(job.id) } catch { problem = error.localizedDescription }
                    }
                case .succeeded:
                    Button("Show in Finder") {
                        let folder = URL(filePath: job.root).appending(path: job.folder)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            }
            if job.state == .running || job.state == .verifying {
                ProgressView(value: job.fraction)
            }
            Text(statusText).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                .textSelection(.enabled)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        let files = "\(job.files.count) file\(job.files.count == 1 ? "" : "s")"
        switch job.state {
        case .queued: return "Waiting · \(files), \(size(job.totalBytes)) · \(job.sourceName)"
        case .running:
            let name = job.files.indices.contains(job.fileIndex) ? job.files[job.fileIndex].filename : ""
            return "\(size(job.bytesDone)) of \(size(job.totalBytes)) · \(name)"
        case .verifying: return "Putting the files in \(job.folder)"
        case .succeeded: return "In \(job.folder) · \(files), \(size(job.totalBytes))"
        case .failed: return job.message ?? "Failed"
        case .cancelled: return "Cancelled · nothing was put in the games folder"
        }
    }
}

/// A new source: the catalog's address, a name, and an access token if the server asks for one.
private struct AddSourceSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("NAS"))
                TextField("Catalog address", text: $address, prompt: Text("https://nas.local/games/catalog.json"))
                SecureField("Access token", text: $token, prompt: Text("Optional"))
            } footer: {
                Text(
                    "A catalog you host yourself (Catalog/README.md). https works anywhere; plain http only on the local network. The token is kept in your Keychain and sent as “Authorization: Bearer” only to the catalog's own server, never to a file hosted elsewhere or after a redirect to another server."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    do {
                        let source = try library.repositories.addSource(name: name, address: address, token: token)
                        Task { await library.repositories.refresh(source.id) }
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// A source's access token: replaced, or removed when left empty.
private struct TokenSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let source: RepositorySource
    @State private var token = ""
    @State private var problem: String?

    var body: some View {
        let state = library.repositories.tokenState(source.id)
        Form {
            Section {
                SecureField("Access token", text: $token, prompt: Text(state == .saved ? "Saved; type a new one to replace it" : state == .none ? "None" : "Couldn't be read"))
            } header: {
                Text(source.name)
            } footer: {
                Text("Sent only to \(source.origin?.text ?? "the catalog's server"). Leave it empty and save to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .unreadable(let message) = state {
                Text("\(message). Saving a token here replaces it.").foregroundStyle(.red)
            }
            if let problem {
                Text("\(problem). The token saved before is unchanged.").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try library.repositories.setToken(token, for: source.id)
                        Task { await library.repositories.refresh(source.id) }
                        dismiss()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// Tools › Sources….
public struct SourcesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("Sources…") { openWindow(id: SourcesView.windowID) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
