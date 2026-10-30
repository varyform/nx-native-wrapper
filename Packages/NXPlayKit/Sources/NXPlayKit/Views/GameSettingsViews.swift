import SwiftUI

/// Settings › Games: the values every game uses unless it has its own, then the controllers.
struct GlobalGameSettings: View {
    @Environment(Library.self) private var library

    var body: some View {
        let settings = library.globalSettings
        Form {
            SettingSections(settings: settings, current: { value($0) }) { setting in
                let follows = library.sharedDefault(for: setting.env)
                let followsLabel = setting.env == "DM_LANG" ? "As built" : "Each game's default"
                SettingRow(
                    setting: setting, own: library.globalChoices[setting.env], follows: follows,
                    followsLabel: followsLabel,
                    resetHelp: follows.map { "Reset to default: \(setting.title(for: $0))" }
                        ?? "Reset to \(followsLabel.lowercased())"
                ) { library.setGlobal($0, for: setting.env) }
            }
            Section {
            } footer: {
                Text(
                    "Every game uses these unless it has its own (Game \u{203A} Game Settings\u{2026}). A game that doesn't offer a value keeps its tested default; one without the language plays its regional twin. Console Mode always starts games in full screen. The settings come from each game's build, so a setting only some games have shows once one of them is built."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ControllerSettings()
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 560)
    }

    private func value(_ setting: LauncherSetting) -> String {
        library.globalChoices[setting.env] ?? library.sharedDefault(for: setting.env)
            ?? setting.defaultValue
    }
}

/// Game › Game Settings…: the game's own list, each row following the global value until the player changes it. The
/// game's own values live in nxnative's store, so its Mac app's settings window shows the same.
struct GameSettingsSheet: View {
    let game: Game
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        let list = library.settingsLists[game.id]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                GameIcon(url: library.icon(for: game)).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Game Settings").font(.title2.bold())
                    Text(game.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(20)
            if let list, !list.settings.isEmpty {
                Form {
                    SettingSections(
                        settings: list.settings, current: { library.value($0, for: game) }
                    ) { setting in
                        let global = library.globalValue(setting, for: game)
                        let follows = global ?? setting.defaultValue
                        SettingRow(
                            setting: setting, own: library.own(setting, for: game),
                            follows: follows, followsLabel: "",
                            resetHelp:
                                "Reset to \(global == nil ? "default" : "global"): \(setting.title(for: follows))"
                        ) { library.setOwn($0, setting, for: game) }
                    }
                }
                .formStyle(.grouped)
            } else if loading {
                ProgressView("Reading the game\u{2019}s settings\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Settings", systemImage: "slider.horizontal.3",
                    description: Text(
                        "nxnative lists a game\u{2019}s settings once it\u{2019}s built. Play or rebuild it, then look again."
                    )
                )
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Use Global Settings") { list.map { library.clearOwn($0, for: game) } }
                    .disabled(
                        !(list?.settings.contains { library.own($0, for: game) != nil } ?? false))
                Text(
                    library.isBusy(game)
                        ? "Changes apply the next time the game starts."
                        : "Shared with the game's Mac app."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task {
            _ = await library.loadGameSettings(for: game)
            loading = false
        }
    }
}
