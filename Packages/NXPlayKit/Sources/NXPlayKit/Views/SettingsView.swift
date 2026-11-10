import SwiftUI

/// The Settings window, one tab per subject: each tab is only as tall as its own settings, so the window fits a small
/// screen (all of them on one page ran under the Dock on a laptop).
public struct SettingsView: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        @Bindable var library = library
        TabView(selection: $library.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            GlobalGameSettings()
                .tabItem { Label("Games", systemImage: "gamecontroller") }
                .tag(SettingsTab.games)
            SaveSettings()
                .tabItem { Label("Saves", systemImage: "externaldrive") }
                .tag(SettingsTab.saves)
            DeviceSettings()
                .tabItem { Label("Devices", systemImage: "iphone") }
                .tag(SettingsTab.devices)
            UpdatesTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
        }
    }
}

public enum SettingsTab: Hashable, Sendable { case general, games, saves, devices, updates }

/// NX Play › Check for Updates…: checks now and shows the result in Settings › Updates.
public struct CheckForUpdatesMenuItem: View {
    @Environment(Library.self) private var library
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        Button("Check for Updates…") {
            library.settingsTab = .updates
            openSettings()
            Task { await library.updater.check() }
        }
    }
}

/// A tab's page: a grouped form at the window's width, as tall as its content but no taller than the screen has room
/// for, scrolling beyond that. The Settings window can't be resized, so a page taller than a laptop's screen left its
/// last settings under the Dock with no way to reach them.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat?

    /// The window's title bar and tab bar, above the page.
    static var chrome: CGFloat { 100 }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom
            } action: { _, height in
                contentHeight = height
            }
            .frame(width: 600, height: min(contentHeight ?? 400, Self.room))
    }

    /// The tallest page the screen shows whole: its visible part, below the menu bar and above the Dock.
    static var room: CGFloat {
        max(300, (NSScreen.main?.visibleFrame.height ?? 800) - chrome)
    }
}

struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

private func exists(_ path: String, _ inside: String = "") -> Bool {
    let base = (path as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: inside.isEmpty ? base : base + "/" + inside)
}

/// Where the games, nxnative and the keys are, and the tools the builds need.
private struct GeneralSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        SettingsPage {
            GamesFoldersSection()
            Section {
                PathField(
                    title: "prod.keys", path: $library.keysPath, directory: false,
                    isValid: exists(library.keysPath))
            }
            UnpackedSettingsSection()
            Section {
                PathField(
                    title: "nxnative repository",
                    path: $library.nxnativePath,
                    directory: true,
                    isValid: exists(library.nxnativePath, "scripts/build_ipa_from_nsp.py")
                )
                Picker("When nxnative has new code", selection: $library.updateBeforePlay) {
                    Text("Ask before playing").tag(UpdateBeforePlay.ask)
                    Text("Update, then play").tag(UpdateBeforePlay.update)
                    Text("Play the current build").tag(UpdateBeforePlay.current)
                }
                Toggle(
                    "Allow a Metal compiler nxnative didn't test", isOn: $library.allowOtherMetal)
                LabeledContent("Tools") {
                    SetupMenuItem()
                }
            } footer: {
                Footer(
                    "Before a play, nxplay looks for new nxnative commits. A game built with older code can update first (a rebuild, and the Mac app packed again) or play as it is; Ask says what the update brings and how long it took last time. Rebuild and Update All Builds always take the latest code. nxnative stops a build when this Mac's Metal compiler (Xcode's) isn't the one it tested its shaders with; the toggle builds anyway, at the risk of shader glitches (nxnative issue #242)."
                )
            }
        }
    }
}

/// Local co-op: which player each controller is in a game, and the controllers connected now (in Settings › Games).
struct ControllerSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Section {
            Picker("Players", selection: $library.controllerPlayers) {
                Text("Each controller is a player").tag(Library.ControllerPlayers.each)
                Text("Keyboard is player 1, controllers from player 2").tag(
                    Library.ControllerPlayers.keyboardOwn)
                Text("Every controller is player 1").tag(Library.ControllerPlayers.merged)
            }
            let merged = library.controllerPlayers == .merged
            if library.offersPressToJoin {
                Toggle("Press a button to join", isOn: $library.pressesToJoin)
                    .disabled(merged)
            }
            let joinsByPress = library.pressesToJoin && library.offersPressToJoin && !merged
            let players = library.gamepad.players
            if players.isEmpty {
                Text("No controller connected").foregroundStyle(.secondary)
            }
            ForEach(players) { player in
                LabeledContent(player.name) {
                    Text(
                        joinsByPress
                            ? "Joins at its first button press"
                            : player.number.map { "Player \($0)" } ?? "Not used (8 players at most)"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Controllers")
        } footer: {
            Footer(
                "In a game each controller is a player of its own, in the order they connected: the first is player 1, together with the keyboard, the next player 2, up to 8. A controller that disconnects gets its player back when it returns. A one-player game sees every controller as player 1. With Press a button to join, a controller becomes a player at its first button press instead, taking the lowest player free, so you choose who is player 1: press on every controller before the game asks how many play. It shows once a game built with a recent nxnative offers it, and doesn't apply when every controller is player 1. The settings apply from a game's next start (nxnative's DM_PAD_MERGE, DM_KBD_PLAYER and DM_PAD_PRESS_TO_JOIN)."
            )
        }
    }
}

/// Save backup to the player's own repository.
private struct SaveSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        SettingsPage {
            Section {
                PathField(
                    title: "Save backup repository", path: $library.saveBackupPath, directory: true,
                    isValid: library.saveBackupPath.isEmpty
                        ? nil : exists(library.saveBackupPath, ".git"),
                    prompt: "None")
            } footer: {
                Footer(
                    "A clone of your own private Git repository. While a game plays, NX Play copies its save into a folder named after it (the-game-name-<title ID>) once the game has saved, commits it and pushes, with your Git credentials. Empty: no backup."
                )
            }
            CloudSavesSection()
        }
    }
}

/// Cloud saves (nxnative's DM_SAVE_SYNC): off, iCloud Drive › nxnative Saves, or a folder of the player's.
private struct CloudSavesSection: View {
    @Environment(Library.self) private var library

    private enum Mode: Hashable { case off, icloud, folder }

    private var mode: Mode {
        switch library.cloudSaves {
        case "": .off
        case "icloud": .icloud
        default: .folder
        }
    }

    var body: some View {
        @Bindable var library = library
        Section {
            Picker(
                "Cloud saves",
                selection: Binding(
                    get: { mode },
                    set: { mode in
                        switch mode {
                        case .off: library.cloudSaves = ""
                        case .icloud: library.cloudSaves = "icloud"
                        case .folder:
                            // a folder asks for one at once; cancelled, the choice stays as it was
                            if let url = PathPicker.choose(
                                directory: true, startingAt: Self.iCloudDrive)
                            {
                                library.cloudSaves = url.path
                            }
                        }
                    })
            ) {
                Text("Off").tag(Mode.off)
                Text("iCloud Drive").tag(Mode.icloud)
                Text("Folder").tag(Mode.folder)
            }
            if mode == .folder {
                PathField(
                    title: "Cloud saves folder", path: $library.cloudSaves, directory: true,
                    isValid: exists(library.cloudSaves))
            }
        } footer: {
            Footer(
                "Each game's save syncs through one file in the folder, <title ID>/save.dmsync, so the game's iPhone app plays on from it: pick the same folder in its own Cloud saves. iCloud Drive is its nxnative Saves folder. When both sides changed since they were last the same, Play asks which save to use, and the other is kept in the save's backups. A game uses this from its next play, a build made before nxnative had cloud saves once it rebuilds. A save made in the last seconds before quitting goes up at the game's next start."
            )
        }
    }

    private static let iCloudDrive = "~/Library/Mobile Documents/com~apple~CloudDocs"
}

/// Install on Device's signing.
private struct DeviceSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        SettingsPage {
            Section {
                Picker("Apple team", selection: $library.teamID) {
                    Text(library.team.map { "Automatic (\($0.name))" } ?? "None in Xcode").tag("")
                    Divider()
                    ForEach(library.teams) { team in
                        Text(team.isFree ? "\(team.name) (Personal Team)" : team.name).tag(team.id)
                    }
                }
            } footer: {
                Footer(
                    "Signs Install on Device: Xcode builds the game for your iPhone or iPad and installs it, no sideloading. Teams come from Xcode › Settings › Apple Accounts; a Personal Team builds without the Increased Memory Limit."
                )
            }
            RemoteSettingsSection()
        }
        .onAppear { library.refreshDevices() }
    }
}

private struct UpdatesTab: View {
    @Environment(Library.self) private var library

    var body: some View {
        SettingsPage {
            Section {
                UpdateSettings()
            } footer: {
                Footer(
                    library.updater.isEnabled
                        ? "NX Play looks for a new release on GitHub at launch and once a day, and downloads it. It installs when you quit, or now with Restart to Update."
                        : "This copy was built from the source: update it with git pull and bin/install."
                )
            }
        }
    }
}

private struct PathField: View {
    let title: LocalizedStringKey
    @Binding var path: String
    let directory: Bool
    /// Nil for an optional field left empty: no mark.
    let isValid: Bool?
    var prompt: LocalizedStringKey? = nil

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path, prompt: prompt.map { Text($0) })
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if let isValid {
                    Image(
                        systemName: isValid
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(isValid ? .green : .orange)
                    .help(isValid ? "Found" : "Not found")
                }
                Button("Choose…") {
                    if let url = PathPicker.choose(directory: directory, startingAt: path) {
                        path = url.path
                    }
                }
            }
        }
    }
}
