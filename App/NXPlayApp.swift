import NXPlayKit
import SwiftUI

@main
struct NXPlayApp: App {
    @State private var library = Library.forLaunch()

    var body: some Scene {
        Window("NX Play", id: "main") {
            RootView()
                .library(library)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem()
                    .library(library)
            }
            CommandGroup(after: .appSettings) {
                SetupMenuItem()
            }
            CommandGroup(after: .appVisibility) {
                Divider()
                UninstallMenuItem()
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Games Folder…") { library.chooseRoot() }
                    .keyboardShortcut("o")
                Button("Refresh") { library.refresh() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .textEditing) {
                RootView.FindMenuItem()
                    .library(library)
            }
            CommandGroup(before: .toolbar) {
                ViewStyleMenuItems()
                    .library(library)
                Divider()
                LogMenuItem()
                    .library(library)
                ConsoleMenuItem()
                    .library(library)
                Divider()
            }
            CommandGroup(before: .help) {
                ControlsButton()
                ChangelogMenuItem()
            }
            CommandMenu("Game") {
                GameMenu()
                    .library(library)
            }
            CommandMenu("Tools") {
                ToolsMenu()
                    .library(library)
            }
        }

        Window("Free Up Space", id: CleanupView.windowID) {
            CleanupView()
                .library(library)
        }
        .defaultSize(width: 760, height: 680)

        Window("Setup", id: SetupView.windowID) {
            SetupView()
                .library(library)
        }
        .windowResizability(.contentSize)

        Window("Uninstall NX Play", id: UninstallView.windowID) {
            UninstallView()
                .library(library)
        }
        .windowResizability(.contentSize)

        Window("Game Controls", id: ControlsView.windowID) {
            ControlsView()
        }
        .windowResizability(.contentSize)

        Window("NX Play Changelog", id: ChangelogView.windowID) {
            ChangelogView()
        }
        .defaultSize(width: 620, height: 700)

        Settings {
            SettingsView()
                .library(library)
        }
    }
}
