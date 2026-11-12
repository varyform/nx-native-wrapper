import Combine
import SwiftUI

/// The main window: the games of the chosen folder above, the selected game's nxplay output below.
public struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    /// The update problem banner, dismissed for this launch.
    @State private var problemDismissed = false
    #if DEBUG
        @Environment(\.openSettings) private var openSettings
    #endif

    public init() {}

    public var body: some View {
        content
            .frame(minWidth: 720, minHeight: 540)
            .navigationTitle("NX Play")
            .toolbar { toolbar }
            .searchable(
                text: Bindable(library).search, placement: .toolbar, prompt: "Search Games"
            )
            .searchFocused($searchFocused)
            .onChange(of: library.searchRequests) { searchFocused = true }
            .toolbar(library.consoleMode ? .hidden : .visible, for: .windowToolbar)
            .background(
                // screenshots show Console Mode in the window, at the README's size, not across a whole screen
                ConsoleWindowController(consoleMode: library.consoleMode && !library.isScreenshot)
            )
            .background(DockProgress())

            .safeAreaInset(edge: .top, spacing: 0) {
                if !library.consoleMode {
                    VStack(spacing: 0) {
                        if library.needsSetup { SetupBanner() }
                        if case .ready(let version, let notes) = library.updater.state {
                            UpdateBanner(version: version, notes: notes)
                        }
                        if let problem = library.updater.problem, !problemDismissed {
                            UpdateProblemBanner(problem: problem) { problemDismissed = true }
                        }
                    }
                }
            }
            // a first launch, or something setup installed has gone: the window that fixes it
            .task { if library.needsSetup { openWindow(id: SetupView.windowID) } }
            .sheet(item: Bindable(library).transfer) { transfer in
                TransferSavesView(transfer: transfer)
            }
            .sheet(item: Bindable(library).notesGame) { game in
                ProfileNotesView(game: game)
            }
            .sheet(item: Bindable(library).removingGame) { game in
                RemoveGameView(game: game)
            }
            .sheet(item: Bindable(library).settingsGame) { game in
                GameSettingsSheet(game: game)
            }
            .sheet(isPresented: Bindable(library).showsUpdateAll) { UpdateAllView() }
            .sheet(item: Bindable(library).saveQuestion) { question in
                SaveChoiceView(question: question)
            }
            .sheet(item: Bindable(library).cloudSaveQuestion) { question in
                CloudSaveChoiceView(question: question)
            }
            .sheet(item: updatePromptShown) { prompt in
                UpdateAskView(prompt: prompt)
            }
            .alert("Can't run nxplay", isPresented: problemShown) {
                Button("OK") {}
            } message: {
                Text(library.problem ?? "")
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                library.refresh()
                library.refreshDevices()
                NSApp.dockTile.badgeLabel = nil  // a failure seen
            }
            #if DEBUG
                .task {
                    if library.screenshotScene == .settings || library.screenshotScene == .devices {
                        openSettings()
                    }
                    if library.screenshotScene == .freeUpSpace {
                        openWindow(id: CleanupView.windowID)
                    }
                }
            #endif
    }

    @ViewBuilder private var content: some View {
        if let host = library.macLink.shownHost, !library.consoleMode {
            RemoteLibraryView(hostID: host)
        } else if library.roots.isEmpty {
            ContentUnavailableView {
                Label("No Games Folder", systemImage: "folder")
            } description: {
                Text(
                    "Add a folder with one subfolder per game, or a game\u{2019}s own folder: its NSP, NSZ, XCI, XCZ or NUP files. Settings can add more."
                )
            } actions: {
                Button("Add Folder…") { library.addRoot() }
                    .buttonStyle(.borderedProminent)
            }
        } else if library.consoleMode {
            ConsoleView()
                .transition(.opacity)
        } else {
            LogSplit()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            MacTabs()
        }
        ToolbarItem(placement: .navigation) {
            ViewStylePicker()
        }
        ToolbarItem(placement: .navigation) {
            SortFilterMenu()
        }
        ToolbarItemGroup {
            ConsoleToggle()
            LogToggle()
            Button {
                library.addRoot()
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a games folder")
            Button {
                library.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Look for new games")
            Button {
                library.extractAll()
            } label: {
                Label("Extract All", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Extract every game not extracted yet, one after another")
            .disabled(library.extractableGames.isEmpty)
            ControlsButton()
        }
    }

    /// Edit › Find Games… (⌘F): a toolbar search field doesn't take ⌘F by itself.
    public struct FindMenuItem: View {
        @Environment(Library.self) private var library

        public init() {}

        public var body: some View {
            Button("Find Games…") { library.findGames() }
                .keyboardShortcut("f")
                .disabled(library.roots.isEmpty || library.consoleMode)
        }
    }

    /// nxplay waits for an answer: a sheet closed any other way than its buttons doesn't play.
    private var updatePromptShown: Binding<UpdatePrompt?> {
        Binding(
            get: { library.updatePrompt },
            set: { if $0 == nil, library.updatePrompt != nil { library.answerUpdate(.cancel) } })
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { library.problem != nil }, set: { if !$0 { library.problem = nil } })
    }
}
