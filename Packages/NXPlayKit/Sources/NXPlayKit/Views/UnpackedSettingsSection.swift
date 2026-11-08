import SwiftUI

/// Settings › General › Compressed Games: Keep Only the Unpacked Copy (Library+Compressed.swift), and the question
/// about the games built already that turning it on asks.
struct UnpackedSettingsSection: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Section {
            Toggle("Keep only the unpacked copy of NSZ and XCZ games", isOn: $library.keepUnpackedOnly)
            Label(
                "This changes the files in your game folders: the compressed ones go to the Trash.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        } header: {
            Text("Compressed Games")
        } footer: {
            Text(
                "nxnative unpacks an NSZ or XCZ into the game's build folder before building it, and keeps the unpacked copy beside the compressed one, so the game takes up its space about twice, and unpacks again whenever the build folder goes. With this on, once a game is built for the Mac, its unpacked NSP or XCI moves into the game folder and the NSZ or XCZ goes to the Trash, where it stays until you empty it. The game builds from the NSP from then on, and plays as before. Files moved already stay as they are when you turn it off."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .alert(
            sweepTitle, isPresented: sweepShown, presenting: library.unpackedSweep
        ) { _ in
            Button("Move to Trash", role: .destructive) { library.sweepUnpacked() }
            Button("Not Now", role: .cancel) { library.unpackedSweep = nil }
        } message: { sweep in
            Text(
                "\(sweep.files == 1 ? "Their compressed file" : "Their \(sweep.files) compressed files") (\(ByteCountFormatter.string(fromByteCount: sweep.size, countStyle: .file))) go to the Trash, and the unpacked copies in their build folders take their place. Other games follow after their next build."
            )
        }
    }

    private var sweepTitle: String {
        let games = library.unpackedSweep?.games ?? 0
        return games == 1 ? "Tidy the game built already?" : "Tidy the \(games) games built already?"
    }

    private var sweepShown: Binding<Bool> {
        Binding(
            get: { library.unpackedSweep != nil },
            set: { if !$0 { library.unpackedSweep = nil } })
    }
}
