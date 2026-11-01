import Foundation

/// Where a build is: the stage it is in and how far that stage has come, from build_ipa_from_nsp.py's
/// `--progress json` events (nxnative's docs/frontends.md, "Building: the NSP script").
public struct BuildProgress: Equatable, Sendable {
    public let stage: Int
    public let stages: Int
    public let name: String
    /// The step within the stage ("splitting"), empty when it has none.
    public let step: String
    /// The stage's own share done, 0 to 0.99 while it runs, nil when its work can't be counted.
    public let stageFraction: Double?
    /// Seconds left in the stage, while the script can tell.
    public let eta: Double?
    /// The step's count as the script words it: "211,200/304,243 files", "1.9/~5.0 GB"; nil without one.
    public var count: String? = nil
    /// The script's note after the count, nil without one.
    public var note: String? = nil
    public let finished: Bool

    public var title: String { step.isEmpty ? name : "\(name) · \(step)" }
    public var percent: Int? { finished ? 100 : stageFraction.map { Int(($0 * 100).rounded()) } }

    /// The whole build done so far, counting the current stage's share.
    public var fraction: Double {
        let within = finished ? 1 : stageFraction ?? 0
        return min(1, max(0, (Double(stage - 1) + within) / Double(max(stages, 1))))
    }

    public var isLastStageDone: Bool { finished && stage == stages }

    /// "4/6 shader split · splitting · 211,200/304,243 files · 69% · 0:04 left"
    public var summary: String {
        var parts = ["\(stage)/\(stages) \(title)"]
        if !finished {
            if let count { parts.append(count) }
            if let note { parts.append(note) }
            if let percent { parts.append("\(percent)%") }
            if let eta { parts.append("\(Self.duration(eta)) left") }
        }
        return parts.joined(separator: " · ")
    }

    /// "0:42", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Reads nxplay's output line by line: the build script's JSON events become the progress and log lines as its
/// `--progress lines` mode would print them (a stage's start and end, its steps, its messages, and every 30 s a line
/// with the count while it moves); anything else (nxplay's own lines, git's, a traceback on stderr) is shown as it is.
///
/// The events are another project's output: every field is read on its own, checked for its type and range, and
/// left out when missing or odd (a later version may drop or change one), so a change shows less, never garbage.
struct BuildOutputReader {
    private(set) var progress: BuildProgress?
    /// nxplay's question before a play, until the job takes it (takeAsk).
    private var ask: UpdateAsk?
    private var stage = 0, stages = 0
    private var name = "", step = ""
    private var stageFraction: Double?, eta: Double?
    private var count: String?, note: String?
    /// When the last count line went to the log, and what it said.
    private var lastBeat: Double?, lastBeatText: String?

    /// lines mode's BEAT: a count line at most this often.
    static let beatInterval = 30.0

    /// The log lines a line of output shows; updates `progress` from an event.
    mutating func read(_ line: String) -> [String] {
        guard line.hasPrefix(#"{"ev": "#), let data = line.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = event["ev"] as? String
        else { return [line] }
        let time = Self.number(event["t"], max: 1e11)
        let clock = time.map(Self.clock) ?? ""
        let k = Self.integer(event["k"]) ?? stage
        switch kind {
        case "stage":
            stage = k
            stages = Self.integer(event["n"]) ?? stages
            name = Self.text(event["name"]) ?? ""
            step = Self.text(event["step"]) ?? ""
            restartStep()
            publish(finished: false)
            return ["\(clock)[\(stage)/\(stages)] \(title) …"]
        case "step":
            step = Self.text(event["step"]) ?? ""
            restartStep()
            publish(finished: false)
            return ["\(clock)[\(stage)/\(stages)] \(title) …"]
        case "progress":
            step = Self.text(event["step"]) ?? step
            stageFraction = Self.number(event["frac"], max: 1)
            eta = Self.number(event["eta"], max: 1e7)
            count = Self.count(
                done: Self.number(event["done"], max: 1e18),
                total: Self.number(event["total"], max: 1e18),
                unit: Self.text(event["unit"]) ?? "", estimate: event["est"] as? Bool ?? false)
            note = Self.text(event["note"]).flatMap { $0.isEmpty ? nil : $0 }
            publish(finished: false)
            return beat(at: time, clock: clock, elapsed: Self.number(event["elapsed"], max: 1e7))
        case "stage_end":
            let ok = event["ok"] as? Bool ?? true
            let elapsed =
                Self.number(event["elapsed"], max: 1e7).map { " (\(BuildProgress.duration($0)))" }
                ?? ""
            let summary = Self.text(event["summary"]).flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            let ended = Self.text(event["name"]) ?? name
            step = ""
            restartStep()
            publish(finished: ok)
            return ["\(clock)\(ok ? "✓" : "✗") [\(k)/\(stages)] \(ended)\(elapsed)\(summary)"]
        case "ask":
            guard let question = UpdateAsk(event: event) else { return [] }
            ask = question
            return ["\u{1B}[34m\(question.logLine)\u{1B}[0m"]  // nxplay's own line, blue as its say
        case "say":
            guard let message = event["msg"] as? String else { return [] }
            return message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        default:
            return []  // an event this version doesn't know: the log stays readable without it
        }
    }

    private var title: String { step.isEmpty ? name : "\(name) · \(step)" }

    mutating func takeAsk() -> UpdateAsk? {
        defer { ask = nil }
        return ask
    }

    /// A new step starts with no count and its own beat.
    private mutating func restartStep() {
        stageFraction = nil
        eta = nil
        count = nil
        note = nil
        lastBeat = nil
        lastBeatText = nil
    }

    private mutating func publish(finished: Bool) {
        guard stage > 0 else { return }
        progress = BuildProgress(
            stage: stage, stages: max(stages, stage), name: name, step: step,
            stageFraction: stageFraction, eta: eta, count: count, note: note, finished: finished)
    }

    /// lines mode's beat: "[13:58:13] [3/6] rewrite · main: 67%, 2/3 modules, 0:36 · ETA 0:04", every 30 s while the
    /// count or the share moves (the first one 30 s into the step). Nothing without a time to go by.
    private mutating func beat(at time: Double?, clock: String, elapsed: Double?) -> [String] {
        guard let time else { return [] }
        guard let last = lastBeat else {
            lastBeat = time
            return []
        }
        guard time - last >= Self.beatInterval else { return [] }
        var parts: [String] = []
        if let percent = stageFraction.map({ Int(($0 * 100).rounded()) }) {
            parts.append("\(percent)%")
        }
        if let count { parts.append(count) }
        if let note { parts.append(note) }
        let state = parts.joined(separator: ", ")
        guard !state.isEmpty, state != lastBeatText else { return [] }  // nothing moved: no line
        lastBeat = time
        lastBeatText = state
        if let elapsed {
            parts.append(
                BuildProgress.duration(elapsed)
                    + (eta.map { " · ETA \(BuildProgress.duration($0))" } ?? ""))
        }
        return ["\(clock)[\(stage)/\(stages)] \(title): \(parts.joined(separator: ", "))"]
    }

    // MARK: - Checked fields

    /// A number from 0 to max (JSON gives Int or Double); nil for anything else.
    static func number(_ value: Any?, max: Double) -> Double? {
        guard let value, !(value is Bool), let number = (value as? NSNumber)?.doubleValue,
            number.isFinite, number >= 0, number <= max
        else { return nil }
        return number
    }

    static func integer(_ value: Any?) -> Int? {
        number(value, max: 10_000).flatMap { $0 == $0.rounded() ? Int($0) : nil }
    }

    /// Text for one line: no line breaks or control characters, at most 120 characters.
    static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = String(
            text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
            }
        )
        .trimmingCharacters(in: .whitespaces)
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// The count as build_ipa_from_nsp.py words it (_count): "1,203/19,592 shaders", "1.9/~5.0 GB", "2,301 files"
    /// without a total; nil without a count.
    static func count(done: Double?, total: Double?, unit: String, estimate: Bool) -> String? {
        guard let done else { return nil }
        let tilde = estimate ? "~" : ""
        if unit == "B" {
            let scale = byteScale(total ?? done)
            let doneText = String(format: "%.1f", done / scale.divisor)
            guard let total, total > 0 else { return "\(doneText) \(scale.unit)" }
            return
                "\(doneText)/\(tilde)\(String(format: "%.1f", total / scale.divisor)) \(scale.unit)"
        }
        let suffix = unit.isEmpty ? "" : " \(unit)"
        guard let total, total > 0 else { return grouped(done) + suffix }
        return "\(grouped(done))/\(tilde)\(grouped(total))\(suffix)"
    }

    private static func grouped(_ value: Double) -> String {
        Int(value.rounded()).formatted(
            .number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// The script's size_unit: GB, MB, else KB, in powers of 1024.
    private static func byteScale(_ bytes: Double) -> (unit: String, divisor: Double) {
        if bytes >= 1_073_741_824 { return ("GB", 1_073_741_824) }
        if bytes >= 1_048_576 { return ("MB", 1_048_576) }
        return ("KB", 1024)
    }

    /// "[21:14:52] ", as the script's own lines start.
    static func clock(_ time: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "[\(formatter.string(from: Date(timeIntervalSince1970: time)))] "
    }
}
