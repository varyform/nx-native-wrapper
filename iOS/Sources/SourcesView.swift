import SwiftUI

/// Sources: the Mac's own repositories of game files (added on the Mac, in Tools › Sources…). A game chosen here is
/// downloaded by the Mac into its games folder; once it's there, its sheet in the library installs it on this device,
/// as any other game. Nothing installs by itself. Each screen belongs to the pairing it opened under (its session):
/// pairing again or unpairing closes Sources, and anything a screen of the old pairing still asks goes nowhere.
struct SourcesView: View {
    @Environment(Launcher.self) private var launcher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // the lists and the session change together (MacSources.reset): these rows are this session's
        let session = launcher.macSources.session
        NavigationStack {
            List {
                let recent = Array(launcher.downloads.reversed().prefix(10))
                if !recent.isEmpty {
                    Section("Downloads on the Mac") {
                        ForEach(recent) { DownloadRow(job: $0, session: session) }
                    }
                }
                Section {
                    if launcher.sources.isEmpty {
                        Text("No sources on \(launcher.mac?.name ?? "the Mac") yet.").foregroundStyle(.secondary)
                    }
                    ForEach(launcher.sources) { source in
                        NavigationLink(value: source) { SourceRow(source: source) }
                            .disabled(!source.enabled)
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text(
                        "Sources are your own catalogs of game files, added on the Mac in Tools › Sources…. A download goes into the Mac's games folder; install the game from the library afterwards."
                    )
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteSource.self) { CatalogView(source: $0, session: session) }
            .refreshable { await launcher.loadSources(refreshing: true) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            let session = launcher.macSources.session
            await launcher.loadSources()
            // the downloads' progress while Sources is open: often while one runs; it stops with the pairing
            while !Task.isCancelled && launcher.macSources.session == session {
                let busy = launcher.downloads.contains(where: \.isActive)
                try? await Task.sleep(for: .seconds(busy ? 2 : 10))
                guard !Task.isCancelled else { break }
                await launcher.loadDownloads()
            }
        }
    }
}

private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private struct SourceRow: View {
    let source: RemoteSource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name).font(.headline)
            Group {
                switch source.state {
                case "loaded": Text("\(source.entries) games · \(source.origin)")
                case "failed": Text(source.error ?? "Can't be read").foregroundStyle(.red)
                case "loading": Text("Reading…")
                default: Text(source.enabled ? source.origin : "Turned off on the Mac")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// A source's games, searchable.
private struct CatalogView: View {
    @Environment(Launcher.self) private var launcher
    let source: RemoteSource
    let session: MacSources.Session
    @State private var search = ""
    @State private var entries: [RemoteEntry]?

    var body: some View {
        List {
            if let entries {
                ForEach(entries) { entry in
                    NavigationLink(value: entry) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(
                                [entry.titleID, entry.version, size(entry.packages.reduce(0) { $0 + $1.bytes })]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .badge(entry.packages.allSatisfy(\.present) ? Text("On the Mac") : nil)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .overlay {
            if entries?.isEmpty == true {
                ContentUnavailableView(
                    search.isEmpty ? "No games" : "No match", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle(source.name)
        .searchable(text: $search, prompt: "Search \(source.name)")
        .navigationDestination(for: RemoteEntry.self) { EntryView(source: source, session: session, entry: $0) }
        .task(id: search) {
            // a pause while typing, so each letter doesn't ask the Mac
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            if let found = await launcher.entries(of: source, matching: search, in: session) { entries = found }
        }
    }
}

/// A game's files: the ones the Mac lacks are ticked, Download to Mac asks for them. Once they're in the games folder,
/// the game's sheet in the library installs it.
private struct EntryView: View {
    @Environment(Launcher.self) private var launcher
    let source: RemoteSource
    let session: MacSources.Session
    @State var entry: RemoteEntry
    @State private var chosen: Set<String> = []

    var body: some View {
        let jobs = launcher.downloads.filter { $0.source == source.id && $0.entry == entry.id }
        let active = jobs.last(where: \.isActive)
        let available = entry.packages.filter { !$0.present && $0.download == nil }
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.title2.bold())
                    Text([entry.publisher, entry.version, entry.titleID].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !entry.description.isEmpty {
                    Text(entry.description).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Files") {
                ForEach(entry.packages) { package in
                    Toggle(
                        isOn: Binding(
                            get: { package.present || chosen.contains(package.id) },
                            set: { if $0 { chosen.insert(package.id) } else { chosen.remove(package.id) } })
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.filename).lineLimit(2)
                            Text(
                                [label(package.kind), package.version.map { "v\($0)" } ?? "", size(package.bytes),
                                 package.checksumLabel, package.present ? "On the Mac" : package.download != nil ? "Downloading" : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(package.present || package.download != nil)
                }
            }
            if let active {
                Section("Downloading to the Mac") { DownloadRow(job: active, session: session) }
            } else if let last = jobs.last, last.state == "failed" || last.state == "cancelled" {
                Section("Last download") { DownloadRow(job: last, session: session) }
            }
            Section {
                let picked = available.filter { chosen.contains($0.id) }
                if !picked.isEmpty {
                    Button("Download to Mac (\(size(picked.reduce(0) { $0 + $1.bytes })))") {
                        Task {
                            await launcher.download(entry, from: source, packages: picked.map(\.id), in: session)
                            await reload()
                        }
                    }
                    .font(.headline)
                }
                if let game = entry.libraryGame ?? jobs.last(where: { $0.libraryGame != nil })?.libraryGame {
                    Button("Open in Library to Install") { launcher.openInLibrary(game, in: session) }
                }
            } footer: {
                Text(
                    "The Mac checks each file's size and the checksum shown with it before it goes into its games folder. Installing on this device is the game's Install in the library, when you choose it."
                        + (entry.packages.contains { $0.checksum == "sha1" }
                            ? " SHA-1 shows a file arrived whole and is the one the catalog lists; it doesn't show who made it."
                            : "")
                )
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chosen = Set(available.map(\.id)) }
        // a download that ends changes what's on the Mac
        .onChange(of: active?.id) { _, now in
            if now == nil { Task { await reload() } }
        }
    }

    private func reload() async {
        if let fresh = await launcher.entries(of: source, matching: "", in: session)?.first(where: { $0.id == entry.id }) {
            entry = fresh
        }
    }

    private func label(_ kind: String) -> String {
        switch kind {
        case "base": "Game"
        case "update": "Update"
        case "dlc": "DLC"
        default: kind
        }
    }
}

private struct DownloadRow: View {
    @Environment(Launcher.self) private var launcher
    let job: RemoteDownload
    let session: MacSources.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.entryName).font(.headline).lineLimit(1)
                Spacer()
                if job.isActive {
                    Button("Cancel", role: .destructive) { Task { await launcher.cancelDownload(job, in: session) } }
                        .buttonStyle(.borderless)
                } else if job.state == "failed" || job.state == "cancelled" {
                    Button("Retry") { Task { await launcher.retryDownload(job, in: session) } }.buttonStyle(.borderless)
                } else if let game = job.libraryGame {
                    Button("Install…") { launcher.openInLibrary(game, in: session) }.buttonStyle(.borderless)
                }
            }
            if job.state == "running" || job.state == "verifying" {
                ProgressView(value: job.fraction)
            }
            Text(status).font(.caption).foregroundStyle(job.state == "failed" ? .red : .secondary)
        }
    }

    private var status: String {
        switch job.state {
        case "queued": "Waiting on the Mac · \(size(job.totalBytes))"
        case "running": "\(size(job.bytesDone)) of \(size(job.totalBytes))"
        case "verifying": "Checking and putting it in the games folder"
        case "succeeded": "In the Mac's games folder · \(size(job.totalBytes))"
        case "cancelled": "Cancelled"
        default: job.message ?? "Failed"
        }
    }
}
