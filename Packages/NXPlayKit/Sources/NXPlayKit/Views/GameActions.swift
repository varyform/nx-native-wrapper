import SwiftUI

/// The commands for a game, in one place for both the card's context menu and the menu bar's Game menu: the HIG
/// asks for a context menu's commands to be in the menu bar too, where they also get shortcuts and menu search.
/// With no game (nothing selected) the menu bar shows them disabled.
struct GameActions: View {
    let game: Game?
    /// The menu bar's: keyboard shortcuts, and Stop always listed so ⌘. stays put.
    var inMenuBar = false
    @Environment(Library.self) private var library

    var body: some View {
        let busy = game.map(library.isBusy) ?? true
        let job = game.flatMap(library.job(for:))
        let active = job?.status.isActive == true
        // these build in the Mac build's folder and rewrite what a kept build runs
        let kept = game?.isKept == true

        Group {
            if let game, !game.isExtracted {
                Button("Extract", systemImage: "square.and.arrow.down") { library.extract(game) }
                    .disabled(busy || !game.canExtract)
                    .shortcut(.return, if: inMenuBar)
            } else {
                Button("Play", systemImage: "play.fill") { game.map(library.play) }
                    .disabled(busy || game == nil)
                    .shortcut(.return, if: inMenuBar)
            }
            if active, job?.kind != .play {
                Button("Cancel", systemImage: "xmark") { job?.cancel() }
                    .shortcut(".", if: inMenuBar)
            } else if active || inMenuBar {
                Button("Stop", systemImage: "stop.fill") { job?.cancel() }
                    .disabled(!active)
                    .shortcut(".", if: inMenuBar)
            }
            // a game whose original files were removed plays its build but cannot be rebuilt
            Button("Rebuild", systemImage: "hammer") { game.map(library.rebuild) }
                .disabled(busy || game?.isExtracted != true || game?.canBuildFromFiles != true)
                .shortcut("b", if: inMenuBar)
            // a game that works stays as it is when nxnative updates; Rebuild still replaces it
            Toggle(
                "Keep This Build", systemImage: "lock",
                isOn: Binding(
                    get: { game?.isKept == true },
                    set: { kept in game.map { library.setKept(kept, $0) } })
            )
            .disabled(game?.canKeep != true)
            // nxnative's settings for the game, as its Mac app's window shows them; they need a build to list them
            Button("Game Settings…", systemImage: "slider.horizontal.3") {
                library.settingsGame = game
            }
            .disabled(game?.state != .ready || game?.titleID == nil)
            .shortcut(",", [.command, .option], if: inMenuBar)
            Menu("Install on Device", systemImage: "apps.iphone") {
                if library.devices.isEmpty {
                    Text(
                        library.isLoadingDevices
                            ? "Looking for devices…"
                            : "No device: pair one in Xcode, with Developer Mode on")
                }
                ForEach(library.devices) { device in
                    Button(
                        "\(device.name) · \(device.model)",
                        systemImage: device.model.contains("iPad") ? "ipad" : "iphone"
                    ) {
                        game.map { library.install($0, on: device) }
                    }
                }
                Divider()
                Button("Look Again", systemImage: "arrow.clockwise") { library.refreshDevices() }
            }
            .disabled(busy || kept || game?.isExtracted != true || game?.canBuildIPA != true)
            Button(game?.ipaURL == nil ? "Build IPA" : "Rebuild IPA", systemImage: "shippingbox") {
                game.map(library.buildIPA)
            }
            .disabled(busy || kept || game?.canBuildIPA != true)
            // a standalone app for the Dock and Launchpad; NX Play keeps playing from the folder
            Button(
                game?.macAppURL == nil ? "Make Mac App" : "Remake Mac App",
                systemImage: "macwindow.badge.plus"
            ) {
                game.map(library.makeMacApp)
            }
            .disabled(busy || kept || game?.isExtracted != true || game?.canBuildFromFiles != true)
            Button("Transfer Saves…", systemImage: "arrow.left.arrow.right") {
                game.map(library.transferSaves)
            }
            .disabled(busy || game?.titleID == nil || game?.buildFolder == nil)
            .shortcut("t", [.command, .shift], if: inMenuBar)

            Divider()

            Button("nxnative Notes…", systemImage: "text.book.closed") {
                library.notesGame = game
            }
            .disabled(game?.titleID == nil)
            .shortcut("i", [.command, .option], if: inMenuBar)
            Button("Show in Finder", systemImage: "folder") {
                game.map {
                    NSWorkspace.shared.activateFileViewerSelecting([$0.buildFolder ?? $0.folder])
                }
            }
            .disabled(game == nil)
            .shortcut("r", [.command, .shift], if: inMenuBar)
            if let ipa = game?.ipaURL {
                Button("Show IPA in Finder", systemImage: "shippingbox") {
                    NSWorkspace.shared.activateFileViewerSelecting([ipa])
                }
            }
            if let app = game?.macAppURL {
                Button("Open Mac App", systemImage: "macwindow") { NSWorkspace.shared.open(app) }
                Button("Show Mac App in Finder", systemImage: "macwindow") {
                    NSWorkspace.shared.activateFileViewerSelecting([app])
                }
            }
            if let save = game?.saveFolder {
                Button("Open Save Folder", systemImage: "tray.full") {
                    NSWorkspace.shared.open(save)
                }
            }
            if let logs = game?.logsFolder {
                Button("Open Build Logs", systemImage: "doc.text") { NSWorkspace.shared.open(logs) }
            }

            Divider()

            Button("Remove Game…", systemImage: "trash", role: .destructive) {
                library.removingGame = game
            }
            .disabled(game.map { !library.canRemove($0) } ?? true)
            .shortcut(.delete, if: inMenuBar)
        }
        // macOS menus show only titles unless the label style asks for the icons too
        .labelStyle(.titleAndIcon)
    }
}

/// The menu bar's Game menu: the selected game's commands.
public struct GameMenu: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        GameActions(game: library.selectedGame, inMenuBar: true)
    }
}

extension View {
    /// A keyboard shortcut in the menu bar only; the context menu would show the same ones as hints.
    fileprivate func shortcut(
        _ key: KeyEquivalent, _ modifiers: EventModifiers = .command, if on: Bool
    ) -> some View {
        keyboardShortcut(on ? KeyboardShortcut(key, modifiers: modifiers) : nil)
    }
}
