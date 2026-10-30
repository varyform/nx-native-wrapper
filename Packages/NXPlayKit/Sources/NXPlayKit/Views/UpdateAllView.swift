import SwiftUI

/// Tools › Update All Builds…: why a game's build can take an hour, told two ways (a modern gamer's shader pre-caching, an
/// old-school computer person's cold compiler cache), the games it builds, and whether to wait for the power adapter.
struct UpdateAllView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("updateAllOnlyWhilePluggedIn") private var onlyWhilePluggedIn = true
    @AppStorage("updateAllExplanation") private var audience = Audience.gamer
    @State private var onBattery = PowerSource.isOnBattery()

    /// Who the explanation is for.
    enum Audience: String { case gamer, oldSchool }

    var body: some View {
        let games = library.updatableGames
        let skips = library.updateSkips
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Update All Builds").font(.title2.bold())
                Spacer()
                Picker("Explain it for", selection: $audience) {
                    Text("Gamer").tag(Audience.gamer)
                    Text("Old school").tag(Audience.oldSchool)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Group {
                switch audience {
                case .gamer: gamer
                case .oldSchool: oldSchool
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if games.isEmpty {
                        Text(
                            "No game to build: every built game is busy, kept, or without its game files."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(games) { Text($0.name).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                    }
                    if let skipped = Self.skipped(skips) {
                        Text(skipped).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Only while plugged in", isOn: $onlyWhilePluggedIn)
                Text(
                    onlyWhilePluggedIn && onBattery
                        ? "Your Mac is on battery: the first build starts when you plug it in."
                        : "On battery, the build that's running finishes and the next one waits until you plug in again."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(games.count == 1 ? "Update 1 Game" : "Update \(games.count) Games") {
                    library.updateAll(onlyWhilePluggedIn: onlyWhilePluggedIn)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(games.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            onBattery = PowerSource.isOnBattery()
        }
    }

    /// Shader pre-caching, as Steam and the consoles do it.
    private var gamer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Think of the shader pre-caching Steam or a console does after an update. nxnative, which runs your games, gets fixes almost every day, and a game takes them in the next time it's built. Most of that build is preparing the game's graphics for your Mac, which takes from a few minutes to an hour. After an Xcode update, every game has to do it once."
            )
            Text(
                "This does it for all your games now, one after another, so none of them makes you wait when you want to play. A game that's already up to date takes a few seconds. Start it before bed, with your Mac plugged in."
            )
        }
    }

    /// A make world with a cold compiler cache.
    private var oldSchool: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "A make world. Each game gets `nxplay --build-only`: it pulls nxnative and rebuilds only when the build came from another nxnative tree (the `# nxnative tree` line in `start_mac.sh`). The long part is compiling the Metal shaders."
            )
            Text(
                "nxnative keeps a ccache of compiled libraries, keyed by the MSL source, the compile flags and the compiler's identity: `metal` and `metallib --version`, the SDK version and build (`dmsh_mtlcache.py`). A shader chain bump (`dmsh_chain.h`) reuses every shader whose MSL didn't change. An Xcode or Metal toolchain update changes the identity, so the cache is cold and everything compiles again."
            )
            Text(
                "Builds run serially, with App Nap off and a power assertion against idle sleep while one runs; the display can still sleep. Queue it, plug in, go to bed."
            )
        }
        .font(.callout)
    }

    /// "Skipped: 2 kept builds, 1 without its game files."
    static func skipped(_ skips: (kept: Int, noFiles: Int)) -> String? {
        let parts = [
            skips.kept == 0 ? nil : skips.kept == 1 ? "1 kept build" : "\(skips.kept) kept builds",
            skips.noFiles == 0
                ? nil
                : skips.noFiles == 1
                    ? "1 game without its game files"
                    : "\(skips.noFiles) games without their game files",
        ].compactMap(\.self)
        return parts.isEmpty ? nil : "Skipped: " + parts.joined(separator: ", ") + "."
    }
}
