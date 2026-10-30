import Foundation
import Testing

@testable import NXPlayKit

/// An update waiting: asked for kindly, never in the way.
@MainActor @Suite final class UpdateNudgeTests {
    private var suites: [String] = []

    deinit {
        suites.forEach(removeTestDefaults)
    }

    private func library() -> Library {
        let suite = testDefaultsName()
        suites.append(suite)
        let library = Library(defaults: UserDefaults(suiteName: suite)!, isScreenshot: true)
        library.terminate = {}
        return library
    }

    private let ready = AppUpdater.State.ready(version: "9.9", notes: Changelog(sections: []))
    private let monday = Date(timeIntervalSince1970: 1_792_972_800)  // 2026-10-26, a Monday

    @Test func theReminderWarmsUpAfterThreeDays() {
        let library = library()
        library.updater.preview(ready, readySince: monday)
        #expect(library.updater.waitingSince(now: monday.addingTimeInterval(86_400)) == nil)
        #expect(library.updater.waitingSince(now: monday.addingTimeInterval(4 * 86_400)) == monday)

        let early = UpdateBanner.message(
            "9.9", library: library, now: monday.addingTimeInterval(3600))
        #expect(early == "NX Play 9.9 is ready. It installs when you quit.")
        let late = UpdateBanner.message(
            "9.9", library: library, now: monday.addingTimeInterval(4 * 86_400))
        #expect(late.hasPrefix("NX Play 9.9 has been waiting since "))
        #expect(late.hasSuffix("Restart to Update takes a few seconds."))
    }

    @Test func onlyAReadyUpdateWaits() {
        let library = library()
        library.updater.preview(.upToDate, readySince: monday)
        #expect(library.updater.waitingSince(now: monday.addingTimeInterval(9 * 86_400)) == nil)
    }

    @Test func yShowsTheUpdateOnlyInConsoleModeAndOnlyWhenReady() {
        let library = library()
        library.handle(.info)
        #expect(!library.showsUpdate)  // no update
        library.updater.preview(ready)
        library.handle(.info)
        #expect(!library.showsUpdate)  // not in Console Mode
        library.handle(.menu)
        library.handle(.info)
        #expect(library.showsUpdate)
    }

    @Test func theCardClosesWithBOrYAndIgnoresTheDirections() {
        let library = library()
        library.updater.preview(ready)
        library.handle(.menu)
        library.handle(.info)
        library.handle(.right)
        library.handle(.down)
        #expect(library.showsUpdate && !library.showsDetails)
        library.handle(.back)
        #expect(!library.showsUpdate && library.consoleMode)  // B closes the card, not Console Mode
        library.handle(.info)
        library.handle(.info)
        #expect(!library.showsUpdate)
        library.handle(.info)
        library.handle(.menu)
        #expect(!library.showsUpdate && !library.consoleMode)
    }

    @Test func aPreviewFakesEachNotice() {
        let updater = library().updater
        updater.preview(AppUpdater.PreviewKind.ready)
        #expect(updater.waitingSince() == nil && updater.problem == nil)
        guard case .ready(let version, _) = updater.state else {
            Issue.record("not ready")
            return
        }
        #expect(AppUpdater.isNewer(version, than: updater.currentVersion))
        updater.preview(AppUpdater.PreviewKind.waiting)
        #expect(updater.waitingSince() != nil)
        updater.preview(AppUpdater.PreviewKind.problem)
        #expect(updater.problem == AppUpdater.moveToApplications)
    }

    @Test func theNextVersionReadsAsNewer() {
        #expect(AppUpdater.nextVersion(after: "1.7.9") == "1.7.10")
        #expect(AppUpdater.nextVersion(after: "2") == "3")
        #expect(AppUpdater.isNewer(AppUpdater.nextVersion(after: "1.7.9"), than: "1.7.9"))
    }

    @Test func aRestartsToUpdate() {
        let library = library()
        var quit = false
        library.terminate = { quit = true }
        library.updater.preview(ready)
        library.handle(.menu)
        library.handle(.info)
        library.handle(.confirm)
        #expect(quit && !library.showsUpdate)
    }
}
