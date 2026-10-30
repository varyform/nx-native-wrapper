import Foundation
import Testing

@testable import NXPlayKit

struct ChangelogTests {
    static let file = """
        # Changelog

        User-visible changes to NX Play.

        ## Unreleased

        ## 1.8.0 — 2026-11-02

        ### Added

        - **Known games are marked:** a green check.
          It explains itself.

        ### Changed

        - **A new icon.**

        ## 1.7.5 — 2026-10-28

        ### Fixed

        - Builds count again.

        A paragraph
        on two lines.

        ## 1.7.4 — 2026-10-20

        - Older.
        """

    @Test func readsReleasesHeadingsItemsAndParagraphs() {
        let log = Changelog(markdown: Self.file)
        // the title, the introduction and an empty Unreleased are left out
        #expect(
            log.sections.map(\.title) == [
                "1.8.0 — 2026-11-02", "1.7.5 — 2026-10-28", "1.7.4 — 2026-10-20",
            ])
        #expect(log.sections.map(\.version) == ["1.8.0", "1.7.5", "1.7.4"])
        #expect(
            log.sections[0].blocks == [
                .heading("Added"),
                .item("**Known games are marked:** a green check. It explains itself."),
                .heading("Changed"), .item("**A new icon.**"),
            ])
        #expect(
            log.sections[1].blocks == [
                .heading("Fixed"), .item("Builds count again."), .text("A paragraph on two lines."),
            ])
    }

    @Test func anUpdateShowsEveryReleaseSinceThisOne() {
        let log = Changelog(markdown: Self.file)
        #expect(log.releases(after: "1.7.4").sections.map(\.version) == ["1.8.0", "1.7.5"])
        #expect(log.releases(after: "1.7.4", upTo: "1.7.5").sections.map(\.version) == ["1.7.5"])
        #expect(log.releases(after: "1.8.0").isEmpty)
    }

    /// bin/release <version> <name>: the name sits between the version and the date.
    @Test func aNamedReleaseKeepsItsVersion() {
        let log = Changelog(
            markdown:
                "## 1.7.12 — Stair Climber — 2026-10-31\n\n### Added\n\n- One.\n\n## 1.7.11 — 2026-10-30\n\n- Two.\n"
        )
        #expect(log.sections.map(\.version) == ["1.7.12", "1.7.11"])
        #expect(log.sections[0].title == "1.7.12 — Stair Climber — 2026-10-31")
        #expect(log.releases(after: "1.7.11").sections.map(\.version) == ["1.7.12"])
    }

    @Test func releaseNotesAreOneUntitledSection() {
        let log = Changelog(markdown: "### Added\n\n- One.\n- Two.\n")
        #expect(log.sections.count == 1 && log.sections[0].title.isEmpty)
        #expect(log.sections[0].blocks == [.heading("Added"), .item("One."), .item("Two.")])
        #expect(Changelog(markdown: "").isEmpty)
    }

    @Test func theCheckoutsChangelogReads() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../CHANGELOG.md").standardized
        let log = Changelog(markdown: try String(contentsOf: root, encoding: .utf8))
        #expect(log.sections.contains { $0.version == "1.7.5" })
        #expect(log.sections.allSatisfy { !$0.blocks.isEmpty })
    }
}
