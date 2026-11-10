import SwiftUI

/// The Mac host's game controls (nxnative dm/host/front_mac.m), in a window to keep beside the game.
public struct ControlsView: View {
    public static let windowID = "controls"

    struct Control: Identifiable {
        let keys: [String]
        let action: LocalizedStringKey
        var id: String { keys.joined() }
    }

    static let controls: [Control] = [
        Control(keys: ["W", "A", "S", "D"], action: "Left stick"),
        Control(keys: ["←", "↑", "↓", "→"], action: "D-pad"),
        Control(keys: ["⇧", "←", "↑", "↓", "→"], action: "Right stick (arrows with Shift held)"),
        Control(keys: ["J", "K", "U", "I"], action: "A / B / X / Y"),
        Control(keys: ["Q", "E"], action: "L / R"),
        Control(keys: ["Z", "C"], action: "ZL / ZR"),
        Control(keys: ["F", "G"], action: "Press left stick / press right stick"),
        Control(keys: ["Return", "Tab"], action: "+ / −"),
        Control(keys: ["Space"], action: "Shake the controller (while held)"),
        Control(keys: ["Click"], action: "Touchscreen"),
        Control(keys: ["⌃⌘F"], action: "Toggle full screen"),
        Control(keys: ["⌘Q"], action: "Quit the game"),
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Key")
                    Text("Switch button")
                }
                .font(.headline)
                .foregroundStyle(.secondary)
                Divider()
                ForEach(Self.controls) { control in
                    GridRow {
                        HStack(spacing: 4) {
                            ForEach(control.keys, id: \.self, content: KeyCap.init)
                        }
                        Text(control.action)
                    }
                }
            }
            Text(
                "Controllers are detected automatically, with buttons by position (right A, bottom B, top X, left Y). Extra controllers become extra players for local co-op."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(verbatim: key)
            .font(.callout.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}

/// Opens the controls window; for menus and toolbars (openWindow needs a view's environment).
public struct ControlsButton: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button {
            openWindow(id: ControlsView.windowID)
        } label: {
            Label("Game Controls", systemImage: "keyboard")
        }
        .help("Keyboard and controller controls in the game")
    }
}
