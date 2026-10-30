import Foundation
import Testing

@testable import NXPlayKit

@Suite struct LineSplitterTests {
    @Test func joinsChunksAndKeepsThePartialLine() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("one\ntw".utf8)) == ["one"])
        #expect(splitter.feed(Data("o\nthree".utf8)) == ["two"])
        #expect(splitter.finish() == ["three"])
        #expect(splitter.finish() == [])
    }

    @Test func aCarriageReturnKeepsTheRedrawnText() {
        var splitter = LineSplitter()
        #expect(
            splitter.feed(Data("⠋ stage 1%\r⠙ stage 2%\r      \rdone\nwindows\r\n\n".utf8)) == [
                "done", "windows", "",
            ])
    }
}

@Suite struct LogBufferTests {
    @Test func dropsTheOldestLinesInBatches() {
        var log = LogBuffer(limit: 8)
        log.append((1...10).map(String.init))
        #expect(log.lines.count == 10)  // under limit + limit / 4
        log.append(["11"])
        #expect(log.lines.map(\.text) == (4...11).map(String.init))
        #expect(log.dropped == 3)
        #expect(log.total == 11)
    }
}

/// build_ipa_from_nsp.py's `--progress json` lines, as json.dumps writes them (the event first, ", " and ": ").
/// Console Mode's words for the build's stages.
@Suite struct PlainProgressTests {
    @Test func stagesInAPlayersWords() {
        #expect(BuildProgress.plainName("Mac shaders") == "Preparing the graphics")
        #expect(BuildProgress.plainName("extract DLC") == "Unpacking the DLC")
        #expect(BuildProgress.plainName("extract v655360") == "Unpacking the game")
        #expect(BuildProgress.plainName("survey: code modules") == "Getting to know the game")
        #expect(BuildProgress.plainName("Unity shader capture") == "Finding the graphics")
        #expect(BuildProgress.plainName("something new") == "something new")  // a stage it doesn't know
    }

    @Test func theSummarySaysTheStepAndWhatsLeft() {
        var progress = BuildProgress(
            stage: 8, stages: 9, name: "Mac shaders", step: "compiling", stageFraction: 0.67,
            eta: 933, finished: false)
        progress.count = "12,339/18,503 shaders"
        progress.note = "18,503 not cached"
        #expect(
            progress.plainSummary
                == "Step 8 of 9 · Preparing the graphics · 12,339/18,503 shaders · 15:33 left")
    }
}

@Suite struct BuildOutputTests {
    let t = 1_793_000_000.5

    @Test func aStageItsStepsAndItsEnd() throws {
        var reader = BuildOutputReader()
        let clock = BuildOutputReader.clock(t)

        #expect(
            reader.read(
                #"{"ev": "stage", "k": 4, "n": 6, "name": "shader split", "step": "checking the inputs", "t": \#(t)}"#
            )
                == ["\(clock)[4/6] shader split · checking the inputs …"])
        var p = try #require(reader.progress)
        #expect(p.stage == 4 && p.stages == 6 && !p.finished && p.percent == nil)
        #expect(p.fraction == 3.0 / 6)

        #expect(
            reader.read(
                #"{"ev": "step", "k": 4, "name": "shader split", "step": "splitting", "t": \#(t)}"#
            ).count == 1)
        #expect(
            reader.read(
                #"{"ev": "progress", "k": 4, "name": "shader split", "step": "splitting", "done": 211200, "total": 304243, "unit": "files", "est": false, "note": "", "frac": 0.69, "eta": 4.2, "elapsed": 37.0, "t": \#(t)}"#
            ).isEmpty)  // the bar's job, not the log's
        p = try #require(reader.progress)
        #expect(p.percent == 69 && p.eta == 4.2)
        #expect(
            p.summary == "4/6 shader split · splitting · 211,200/304,243 files · 69% · 0:04 left")
        #expect(abs(p.fraction - 3.69 / 6) < 1e-9)

        #expect(
            reader.read(
                #"{"ev": "stage_end", "k": 4, "name": "shader split", "ok": true, "summary": "28669 shaders", "elapsed": 377.2, "t": \#(t)}"#
            ) == ["\(clock)✓ [4/6] shader split (6:17): 28669 shaders"])
        p = try #require(reader.progress)
        #expect(p.finished && !p.isLastStageDone && p.fraction == 4.0 / 6)
    }

    @Test func aFailedStageAndTheLastOne() throws {
        var reader = BuildOutputReader()
        _ = reader.read(
            #"{"ev": "stage", "k": 6, "n": 6, "name": "Mac host", "step": "", "t": \#(t)}"#)
        #expect(
            reader.read(
                #"{"ev": "stage_end", "k": 6, "name": "Mac host", "ok": false, "summary": "", "elapsed": 3, "t": \#(t)}"#
            )
            .first?.hasSuffix("✗ [6/6] Mac host (0:03)") == true)
        #expect(reader.progress?.finished == false)  // a failed stage isn't done
        _ = reader.read(
            #"{"ev": "stage", "k": 6, "n": 6, "name": "Mac host", "step": "", "t": \#(t)}"#)
        _ = reader.read(
            #"{"ev": "stage_end", "k": 6, "name": "Mac host", "ok": true, "summary": "", "elapsed": 3, "t": \#(t)}"#
        )
        #expect(reader.progress?.isLastStageDone == true && reader.progress?.fraction == 1)
    }

    @Test func countsAsTheScriptWordsThem() {
        #expect(
            BuildOutputReader.count(done: 1203, total: 19592, unit: "shaders", estimate: false)
                == "1,203/19,592 shaders")
        #expect(
            BuildOutputReader.count(done: 2301, total: nil, unit: "files", estimate: false)
                == "2,301 files")
        #expect(BuildOutputReader.count(done: 3, total: 9, unit: "", estimate: false) == "3/9")
        #expect(
            BuildOutputReader.count(
                done: 2_040_109_465, total: 5_368_709_120, unit: "B", estimate: true)
                == "1.9/~5.0 GB")
        #expect(
            BuildOutputReader.count(done: 524_288, total: nil, unit: "B", estimate: false)
                == "512.0 KB")
        #expect(
            BuildOutputReader.count(done: nil, total: 100, unit: "files", estimate: false) == nil)
    }

    @Test func aBeatLineEvery30SecondsWhileTheCountMoves() {
        var reader = BuildOutputReader()
        _ = reader.read(
            #"{"ev": "stage", "k": 4, "n": 6, "name": "shader split", "step": "splitting", "t": \#(t)}"#
        )
        func progress(_ s: Double, _ done: Int) -> [String] {
            reader.read(
                #"{"ev": "progress", "k": 4, "name": "shader split", "step": "splitting", "done": \#(done), "total": 1000, "unit": "files", "est": false, "note": "", "frac": \#(Double(done) / 1000), "eta": 60, "elapsed": \#(s), "t": \#(t + s)}"#
            )
        }
        #expect(progress(1, 10).isEmpty)  // the step's first count starts the clock
        #expect(progress(20, 300).isEmpty)  // too soon
        #expect(
            progress(31, 500) == [
                "\(BuildOutputReader.clock(t + 31))[4/6] shader split · splitting: 50%, 500/1,000 files, 0:31 · ETA 1:00"
            ])
        #expect(progress(45, 600).isEmpty)
        #expect(progress(62, 500).count == 0)  // the same as the last line: nothing moved
        #expect(progress(70, 900).count == 1)
    }

    /// A later nxnative may drop a field, rename one or change its type: the reader shows less, never garbage, and
    /// doesn't crash.
    @Test func oddOrMissingFieldsShowLessNotGarbage() throws {
        var reader = BuildOutputReader()
        _ = reader.read(
            #"{"ev": "stage", "k": "four", "n": -6, "name": 42, "step": null, "t": "now"}"#)
        #expect(reader.progress == nil)  // no usable stage number: nothing to show yet
        _ = reader.read(
            #"{"ev": "stage", "k": 2, "n": 3, "name": "Mac shaders\ncompiling", "step": ""}"#)
        var p = try #require(reader.progress)
        #expect(p.name == "Mac shaders compiling")  // a line break in a name doesn't break the line

        let shown = reader.read(
            #"{"ev": "progress", "k": 2, "done": "many", "total": -5, "unit": 7, "est": "yes", "note": ["x"], "frac": 5, "eta": -3, "elapsed": 1e30, "t": 1e40}"#
        )
        #expect(shown.isEmpty)
        p = try #require(reader.progress)
        #expect(p.count == nil && p.note == nil && p.stageFraction == nil && p.eta == nil)
        #expect(p.summary == "2/3 Mac shaders compiling")

        _ = reader.read(#"{"ev": "progress", "k": 2, "done": true, "total": 10, "frac": true}"#)
        #expect(reader.progress?.count == nil && reader.progress?.stageFraction == nil)  // a Bool isn't a number

        _ = reader.read(
            #"{"ev": "progress", "k": 2, "done": 5, "total": 10, "note": "\#(String(repeating: "x", count: 500))"}"#
        )
        #expect(reader.progress?.note?.count == 120)  // a runaway note is cut
        #expect(reader.read(#"{"ev": "say", "msg": 12}"#).isEmpty)
        #expect(
            reader.read(#"{"ev": "stage_end"}"#).first?.contains("✓ [2/3] Mac shaders compiling")
                == true)
    }

    @Test func messagesAndOtherLines() {
        var reader = BuildOutputReader()
        #expect(
            reader.read(
                #"{"ev": "say", "msg": "[13:57:00] [RED] 3 file(s) could not be read\nsecond line", "t": \#(t)}"#
            )
                == ["[13:57:00] [RED] 3 file(s) could not be read", "second line"])
        #expect(
            reader.read("nxnative updated: 1 new commit, rebuilding") == [
                "nxnative updated: 1 new commit, rebuilding"
            ])
        #expect(
            reader.read("Traceback (most recent call last):") == [
                "Traceback (most recent call last):"
            ])
        #expect(reader.read(#"{"ev": "something new", "t": \#(t)}"#).isEmpty)  // a later event this build doesn't know
        #expect(reader.read(#"{"ev": broken"#) == [#"{"ev": broken"#])
        #expect(reader.progress == nil)
    }
}

@Suite struct EnvironmentTests {
    @Test func putsTheToolsFirstAndDropsXcodeInjections() {
        let env = NXPlayCommand.environment(
            nxnative: "/r", keys: "/k", venv: "/w/.venv",
            base: [
                "PATH": "/usr/bin:/opt/homebrew/bin", "DYLD_INSERT_LIBRARIES": "x", "HOME": "/h",
            ],
            home: "/h"
        )
        #expect(
            env["PATH"]
                == "/h/.local/share/mise/shims:/h/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin"
        )
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["NXNATIVE"] == "/r" && env["NX_KEYS"] == "/k" && env["HOME"] == "/h")
        #expect(env["NXPLAY_VENV"] == "/w/.venv")
    }
}
