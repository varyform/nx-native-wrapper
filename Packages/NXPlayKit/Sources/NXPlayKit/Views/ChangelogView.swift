import SwiftUI

/// Releases as the changelog reads: a title per release, its headings, items and paragraphs, with their inline
/// markdown (bold, code, links).
struct ChangelogContent: View {
    let changelog: Changelog

    var body: some View {
        ScrollView {
            ChangelogBlocks(changelog: changelog)
                .padding(20)
        }
    }
}

/// The releases' blocks, without a scroll view of their own.
struct ChangelogBlocks: View {
    let changelog: Changelog

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(changelog.sections) { section in
                if !section.title.isEmpty {
                    Text(section.title).font(.title2.bold())
                        .padding(.top, section.id == changelog.sections.first?.id ? 0 : 14)
                }
                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                    Self.view(block)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // What's New in Settings opens from a LabeledContent, whose trailing alignment its popover inherits
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private static func view(_ block: Changelog.Block) -> some View {
        switch block {
        case .heading(let text): Text(inline(text)).font(.headline).padding(.top, 4)
        case .item(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .text(let text): Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Help › NX Play Changelog: every release, newest first.
public struct ChangelogView: View {
    public static let windowID = "changelog"

    public init() {}

    public var body: some View {
        if let changelog = Changelog.bundled, !changelog.isEmpty {
            ChangelogContent(changelog: changelog)
        } else {
            ContentUnavailableView(
                "No Changelog", systemImage: "doc.text",
                description: Text("This copy of NX Play doesn't carry its changelog."))
        }
    }
}

/// Opens the changelog window; for menus (openWindow needs a view's environment).
public struct ChangelogMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Button("NX Play Changelog") { openWindow(id: ChangelogView.windowID) }
    }
}

/// An update's changes since this version, before it's installed.
struct WhatsNewButton: View {
    let version: String
    let notes: Changelog
    @State private var shows = false

    var body: some View {
        if !notes.isEmpty {
            Button("What's New") { shows = true }
                .popover(isPresented: $shows, arrowEdge: .bottom) {
                    ChangelogContent(changelog: notes)
                        .frame(width: 520, height: 460)
                }
                .help("What NX Play \(version) changes")
        }
    }
}
