import SwiftUI

/// Over the games when the player asks (Y, or the top bar's pill): what the waiting update brings, and a restart that
/// installs it in a few seconds. A restarts, B or Y close it; a click outside closes it too.
struct UpdateCard: View {
    let version: String
    let notes: Changelog
    let gamepad: Gamepad
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .contentShape(.rect)
                .onTapGesture { library.showsUpdate = false }
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Logo().frame(height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NX Play \(version)").font(.largeTitle.bold())
                        Text(Self.subtitle(library: library))
                            .font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                }
                if !notes.isEmpty {
                    ScrollView {
                        ChangelogBlocks(changelog: notes).font(.title3)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 32) {
                    action(gamepad.symbol(for: .confirm) ?? "return", "Restart to Update") {
                        library.handleUpdate(.confirm)
                    }
                    action(gamepad.symbol(for: .back) ?? "escape", "Later") {
                        library.handleUpdate(.back)
                    }
                }
                .font(.title3.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(36)
            .frame(width: 760)
            .background(RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }

    /// "Restart takes a few seconds; you're back here after." or, waiting days, since when.
    static func subtitle(library: Library) -> String {
        if let since = library.updater.waitingSince() {
            return
                "Waiting since \(since.formatted(.dateTime.weekday(.wide))). Restarting takes a few seconds."
        }
        return "Ready to install. Restarting takes a few seconds."
    }

    /// A button hint the mouse can press too.
    private func action(_ symbol: String, _ title: LocalizedStringKey, _ run: @escaping () -> Void)
        -> some View
    {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }
}
