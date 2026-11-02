import Foundation

/// CHANGELOG.md, as far as NX Play draws it: a section per release ("## 1.7.5 — 2026-10-28", "## Unreleased"), each
/// with its "### Added" headings, "- " items and paragraphs; inline markdown stays in the text, and image lines (the
/// release page's screenshots) are left out. A release's notes on
/// GitHub are one section's body, without the "##" line: they read as one untitled section.
public struct Changelog: Equatable, Sendable {
    public struct Section: Equatable, Sendable, Identifiable {
        public let title: String
        public var blocks: [Block]
        public var id: String { title }

        /// "1.7.5" of "1.7.5 — 2026-10-28"; nil for Unreleased or an untitled section.
        public var version: String? {
            let first = title.split(separator: " ").first.map(String.init) ?? ""
            return first.first?.isNumber == true ? first : nil
        }
    }

    public enum Block: Equatable, Sendable, Hashable {
        case heading(String)
        case item(String)
        case text(String)
    }

    public let sections: [Section]

    public var isEmpty: Bool { sections.isEmpty }

    public init(sections: [Section]) { self.sections = sections }

    public init(markdown: String) {
        let lines = markdown.components(separatedBy: .newlines)
        let titled = lines.contains { $0.hasPrefix("## ") }
        var sections: [Section] = titled ? [] : [Section(title: "", blocks: [])]
        var continues = false  // the next indented line belongs to the last block
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                sections.append(Section(title: String(line.dropFirst(3)), blocks: []))
                continues = false
                continue
            }
            // the file's title and introduction come before the first release
            guard !sections.isEmpty, !line.hasPrefix("# ") else { continue }
            if trimmed.isEmpty {
                continues = false
            } else if trimmed.hasPrefix("![") {
                // a screenshot for the GitHub release page: What's New is text only
                continues = false
            } else if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].blocks.append(.heading(heading))
                continues = false
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                sections[sections.count - 1].blocks.append(.item(String(line.dropFirst(2))))
                continues = true
            } else if continues || line.first?.isWhitespace == true,
                let last = sections[sections.count - 1].blocks.popLast()
            {
                sections[sections.count - 1].blocks.append(Self.joined(last, trimmed))
            } else {
                sections[sections.count - 1].blocks.append(.text(trimmed))
                continues = true
            }
        }
        self.sections = sections.filter { !$0.blocks.isEmpty }
    }

    private static func joined(_ block: Block, _ line: String) -> Block {
        switch block {
        case .item(let text): .item(text + " " + line)
        case .text(let text): .text(text + " " + line)
        case .heading: block
        }
    }

    /// The releases after `current`, up to and including `latest`: what an update brings.
    public func releases(after current: String, upTo latest: String? = nil) -> Changelog {
        Changelog(
            sections: sections.filter { section in
                guard let version = section.version else { return false }
                return AppUpdater.isNewer(version, than: current)
                    && latest.map { !AppUpdater.isNewer(version, than: $0) } ?? true
            })
    }

    /// The changelog an app carries in its Resources; nil without one.
    public static func of(app: URL) -> Changelog? {
        read(app.appending(path: "Contents/Resources/CHANGELOG.md"))
    }

    /// This app's changelog (the checkout's, for a build run from it).
    public static var bundled: Changelog? {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap(read)
            ?? AppHome.sourceRoot.flatMap { read($0.appending(path: "CHANGELOG.md")) }
    }

    private static func read(_ file: URL) -> Changelog? {
        (try? String(contentsOf: file, encoding: .utf8)).map(Changelog.init(markdown:))
    }
}
