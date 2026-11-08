import Foundation
import Testing

@testable import NXPlayKit

struct GameProfileTests {
    static let web = URL(
        string: "https://github.com/seedds/nxnative/blob/HEAD/dm/games/0100F2C0115B6000/README.md")

    static func profile(
        header: String, gallery: String? = nil, validated: String? = nil, readme: String = ""
    ) -> GameProfile {
        GameProfile(
            titleID: "0100F2C0115B6000",
            gameTSV: header
                + "\nname\tThe Legend of Zelda: Tears of the Kingdom\ntitle_id\t0100F2C0115B6000\n",
            galleryNote: gallery, validated: validated, hasSmokeRoute: false, readme: readme,
            notesURL: web)
    }

    @Test func readsTheStageFromTheHeaderAndTheGallery() {
        let bringUp = Self.profile(
            header:
                "# Game profile of Super Mario 3D World (Switch). In bring-up: on the Mac 3D World reaches World 1-1.\n# Format: see dm/games/README.md; bring-up and measurements in README",
            gallery: "60 fps with 1.4.3")
        #expect(bringUp.name == "The Legend of Zelda: Tears of the Kingdom")
        #expect(bringUp.stage == .bringUp)
        #expect(bringUp.headline == "In bring-up: on the Mac 3D World reaches World 1-1")

        let plain = Self.profile(header: "# Game profile of X. In bring-up")
        #expect(plain.stage == .bringUp && plain.headline == "In bring-up")
        #expect(
            Self.profile(header: "# Metroid Dread. Bring-up has just started: values are Mario's")
                .stage == .bringUp)

        // "bring-up" alone (the format note) isn't a stage
        let tested = Self.profile(
            header: "# Format: see dm/games/README.md; bring-up and measurements in README",
            gallery: "")
        #expect(tested.stage == .tested && tested.headline == "Tested on Mac or iPhone")
        #expect(Self.profile(header: "# Mac bring-up and validation: README").stage == .profiled)
    }

    @Test func readsTheLastGreenRun() {
        let text =
            "# The chain…\n# mode <TAB> chain=…\nfull\tchain=a78f commit=337186cf3c+dirty date=2026-10-28 machine=Mac16,7 macos=27.2\n"
        #expect(GameProfile.validatedRun(text) == "2026-10-28 · Mac16,7 · macOS 27.2")
        #expect(GameProfile.validatedRun("# only comments\n") == nil)
    }

    @Test func theSummaryIsTheReadmesOpeningWithLinksMadeAbsolute() {
        let readme = """
            # ANIMAL WELL (`010020D01AD24000`)

            Update 1.0.10. See the [last green record](validated.tsv) and [docs](../../../docs/x.md#y).

            On the Mac: the [site](https://example.com) works.

            ## What it needs

            | a | b |
            """
        let profile = Self.profile(header: "#", readme: readme)
        #expect(!profile.summary.contains("What it needs") && !profile.summary.contains("# ANIMAL"))
        #expect(
            profile.summary.contains(
                "[last green record](https://github.com/seedds/nxnative/blob/HEAD/dm/games/0100F2C0115B6000/validated.tsv)"
            ))
        #expect(
            profile.summary.contains(
                "[docs](https://github.com/seedds/nxnative/blob/HEAD/docs/x.md#y)"))
        #expect(profile.summary.contains("[site](https://example.com)"))
        #expect(GameProfile.resolvingLinks("a [b](c.tsv) d", against: nil) == "a b d")
    }

    @Test func readsTheGalleryAndTheRemote() throws {
        let repo = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.createDirectory(
            at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appending(path: "docs/images"), withIntermediateDirectories: true)
        try
            "# header\nzelda.jpg\tZelda\t60 fps with 1.4.3\t 0100f2c0115b6000\nwell.jpg\tWell\t\t010020D01AD24000\n"
            .write(
                to: repo.appending(path: "docs/images/gallery.tsv"), atomically: true,
                encoding: .utf8)
        #expect(
            GameProfile.gallery(repo.appending(path: "docs/images/gallery.tsv"))
                == ["0100F2C0115B6000": "60 fps with 1.4.3", "010020D01AD24000": ""])

        for (url, expected) in [
            ("git@github.com:seedds/nxnative.git", "https://github.com/seedds/nxnative/blob/HEAD/"),
            ("https://github.com/seedds/nxnative", "https://github.com/seedds/nxnative/blob/HEAD/"),
            ("https://gitlab.com/a/b.git", nil),
        ] {
            try
                "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(url)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                .write(to: repo.appending(path: ".git/config"), atomically: true, encoding: .utf8)
            #expect(GameProfile.webRoot(repo)?.absoluteString == expected)
        }
    }

    @Test func findsTheProfilesCommitsSinceTheBuild() throws {
        let repo = FileManager.default.temporaryDirectory.appending(
            path: "nxplay-news-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let profile = repo.appending(path: "dm/games/0100F2C0115B6000")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        func git(_ args: String...) {
            _ = ProfileNews.git(repo, ["-c", "user.name=t", "-c", "user.email=t@t"] + args)
        }
        git("init", "-q")
        try "a".write(to: profile.appending(path: "game.tsv"), atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Zelda: profile")
        let built = try #require(ProfileNews.git(repo, ["rev-parse", "HEAD^{tree}"]))
        try "b".write(to: repo.appending(path: "other.txt"), atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Host: something else")
        try "c".write(to: profile.appending(path: "game.tsv"), atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Zelda: fix the sky")

        let tip = try #require(ProfileNews.git(repo, ["rev-parse", "HEAD^{tree}"]))
        let news = ProfileNews.read(
            repo: repo,
            builds: [
                "old copy": .init(titleID: "0100F2C0115B6000", tree: built),
                // the same game rebuilt in another folder: nothing new for it
                "fresh copy": .init(titleID: "0100F2C0115B6000", tree: tip),
                "other game": .init(titleID: "0100000000010000", tree: built),
            ])
        #expect(news["old copy"]?.map(\.subject) == ["Zelda: fix the sky"])
        #expect(news["fresh copy"] == nil)
        #expect(news["other game"] == nil)  // no commits to its profile
    }
}
