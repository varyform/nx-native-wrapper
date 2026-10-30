import AppKit
import SwiftUI

/// Console Mode: the window full screen. The selected game's eShop banner fills the upper part edge to edge, the clock
/// and controller over its top and the game's name and badges over its foot; the games as a carousel of their artwork
/// below it, button hints at the bottom. Down opens the selected game's details: the banner and the name slide up and
/// the store page's text, facts and screenshots take the row's place. A controller, the arrow keys with Return and
/// Esc, or the mouse drive it.
struct ConsoleView: View {
    @Environment(Library.self) private var library
    @FocusState private var focused: Bool

    static let tile = 240.0

    var body: some View {
        let games = library.navigableGames  // the extracted ones
        let selected = games.first { $0.id == library.selection } ?? games.first
        let details = library.showsDetails && selected != nil
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // the banner takes what the carousel and the hints leave: about half of the screen
                let height = geometry.size.height
                let banner = max(0, height - Carousel.height)
                // the details take about 55% of the screen; the name stays clear of the top bar
                let lift =
                    details ? min(max(0, height * 0.55 - Carousel.height), max(0, banner - 300)) : 0
                VStack(spacing: 0) {
                    Banner(game: selected, banner: selected.flatMap(library.banner(for:)))
                        .frame(height: banner)
                        .overlay(alignment: .bottomLeading) {
                            if let selected {
                                Caption(game: selected, job: library.job(for: selected))
                                    .padding(.horizontal, 56)
                                    .contentShape(.rect)
                                    .onTapGesture { library.showsDetails.toggle() }
                            }
                        }
                    if games.isEmpty {
                        Text("No games ready to play yet").font(.largeTitle.bold())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(height: Carousel.height)
                    } else {
                        Carousel(games: games, selection: selected?.id)
                            .opacity(details ? 0 : 1)
                    }
                }
                .offset(y: -lift)
                .overlay(alignment: .bottom) {
                    if details, let selected {
                        DetailsPanel(game: selected)
                            .frame(height: Carousel.height + lift)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.1), value: details)
            .overlay(alignment: .top) {
                TopBar(gamepad: library.gamepad)
                    .padding(.horizontal, 56)
                    .padding(.top, 40)
            }
            // the build beside the hints, in the layout: as an overlay of the one-line hints it rose over the tiles
            // the hints over the build's reserved room, at their own width: beside it they were squeezed letter by letter
            FooterBuild(jobs: library.buildingJobs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    Hints(
                        game: selected, gamepad: library.gamepad,
                        mode: !details
                            ? .row : library.detailsFocus == .screenshots ? .screenshots : .text
                    )
                    .fixedSize()
                }
                .animation(.easeInOut(duration: 0.25), value: library.buildingJobs.isEmpty)
                .padding(.horizontal, 56)
                .padding(.bottom, 36)
        }
        .background { Backdrop(game: selected) }
        .overlay {
            if library.viewingShot, let selected {
                ShotViewer(
                    shots: library.screenshots(for: selected), index: library.shotIndex,
                    gamepad: library.gamepad
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: library.viewingShot)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) {
            library.handle(.left)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            library.handle(.right)
            return .handled
        }
        .onKeyPress(.upArrow) {
            library.handle(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            library.handle(.down)
            return .handled
        }
        .onKeyPress(.return) {
            library.handle(.confirm)
            return .handled
        }
        .onExitCommand { library.handle(.back) }
    }
}

/// The toolbar button.
struct ConsoleToggle: View {
    @Environment(Library.self) private var library

    var body: some View {
        Button {
            library.consoleMode.toggle()
        } label: {
            Label("Console Mode", systemImage: "gamecontroller")
        }
        .help("Console Mode: full screen, for a controller (⇧⌘F, or the controller's Menu button)")
    }
}

/// View › Console Mode, ⇧⌘F.
public struct ConsoleMenuItem: View {
    @Environment(Library.self) private var library

    public init() {}

    public var body: some View {
        Button(library.consoleMode ? "Exit Console Mode" : "Console Mode") {
            library.consoleMode.toggle()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}
