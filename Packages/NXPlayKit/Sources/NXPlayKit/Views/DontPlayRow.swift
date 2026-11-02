import SwiftUI

/// The last row of Play's questions (UpdateAskView, SaveChoiceView): back to the games without playing. A row like
/// the answers, so Console Mode's controller can move to it (issue #9), with the button that does it from anywhere
/// (B, or Esc) at its end.
struct DontPlayRow: View {
    let highlighted: Bool
    let action: () -> Void
    @Environment(Library.self) private var library

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Don\u{2019}t Play").font(.headline)
                    Text("Back to the games").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if library.consoleMode {
                    Image(systemName: library.gamepad.symbol(for: .back) ?? "escape")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(library.consoleMode && highlighted ? 1 : 0)
        )
        .keyboardShortcut(.cancelAction)
    }
}
