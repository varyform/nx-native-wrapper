import Foundation

/// One setting of a game's settings list: nxnative's `launcher.json` (docs/frontends.md, The settings list, and
/// docs/launcher.schema.json), which nxplay writes beside the game's launcher as `<title ID>_build/nxplay-settings.json`
/// with nxnative's dm/games/settings.py, as a Mac app carries it. Each setting is an environment variable the game reads
/// when it starts (DM_FPS_TARGET=30).
public struct LauncherSetting: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One of the values; each with its label.
        case choice([Option])
        /// A number from min to max in steps, shown as a percentage.
        case range(min: Double, max: Double, step: Double)
        /// The value the variable takes on and off.
        case toggle(on: String, off: String)
    }

    public struct Option: Equatable, Sendable, Hashable {
        public let value: String
        public let label: String
    }

    public let env: String
    public let kind: Kind
    public let section: String
    public let label: String
    public let note: String
    /// The tested default for this game on the Mac (profile defaults resolved).
    public let defaultValue: String
    /// `level: basic`: shown first, the rest behind Advanced.
    public let isBasic: Bool
    /// `needs: <VAR>=<value>`: a sub-setting, drawn only while that row has that value.
    public let needs: Needs?

    public struct Needs: Equatable, Sendable {
        public let env: String
        public let value: String
    }

    public var id: String { env }

    /// The values to choose from, in order: a choice's, a toggle's on and off, a range's steps.
    public var values: [String] {
        switch kind {
        case .choice(let options): return options.map(\.value)
        case .toggle(let on, let off): return [on, off]
        case .range(let min, let max, let step):
            guard step > 0 else { return [Self.number(min, step: step)] }
            let count = Int(((max - min) / step).rounded(.down))
            guard count < 1000 else { return [] }  // a list no one can pick from
            return (0...count).map { Self.number(min + Double($0) * step, step: step) }
        }
    }

    /// Whether this build offers the value, as the app's launcher checks a saved choice.
    public func accepts(_ value: String) -> Bool {
        switch kind {
        case .choice(let options): return options.contains { $0.value == value }
        case .toggle(let on, let off): return value == on || value == off
        case .range(let min, let max, _):
            guard let number = Double(value), number.isFinite else { return false }
            return number >= min - 1e-9 && number <= max + 1e-9
        }
    }

    /// The same value written another way: "1.0" and "1" for a range.
    public func same(_ a: String, _ b: String) -> Bool {
        guard case .range = kind, let x = Double(a), let y = Double(b) else { return a == b }
        return abs(x - y) < 1e-9
    }

    /// How a value reads in a menu: its option's label, On or Off, a percentage.
    public func title(for value: String) -> String {
        switch kind {
        case .choice(let options): return options.first { $0.value == value }?.label ?? value
        case .toggle(let on, _): return value == on ? "On" : "Off"
        case .range:
            guard let number = Double(value) else { return value }
            return "\(Int((number * 100).rounded()))%"
        }
    }

    /// A range's value as text, written as its steps are.
    func number(_ value: Double) -> String {
        guard case .range(_, _, let step) = kind else { return String(value) }
        return Self.number(value, step: step)
    }

    /// A step value as text: as many decimals as the step has ("0.75", "1.0").
    static func number(_ value: Double, step: Double) -> String {
        var decimals = 1
        while decimals < 4,
            abs(step * pow(10, Double(decimals)) - (step * pow(10, Double(decimals))).rounded())
                > 1e-6
        {
            decimals += 1
        }
        return String(format: "%.\(decimals)f", value)
    }
}

/// A game's settings list. Read defensively, like the build's progress events: it's another project's file, so a
/// field this version doesn't know is ignored, a row of a kind it can't draw is left out, and a malformed row is
/// skipped rather than shown wrong (schema 1 grows only by optional fields; a new kind would be schema 2).
public struct LauncherSettings: Equatable, Sendable {
    public let titleID: String?
    public let settings: [LauncherSetting]

    public subscript(env: String) -> LauncherSetting? { settings.first { $0.env == env } }

    /// nxplay's copy beside the launcher.
    public static let fileName = "nxplay-settings.json"

    /// The list in a file; nil without one, or when it can't be read.
    public static func read(_ file: URL) -> LauncherSettings? {
        (try? Data(contentsOf: file)).flatMap(parse)
    }

    static func parse(_ data: Data) -> LauncherSettings? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = object["settings"] as? [Any]
        else { return nil }
        // no schema is 1; a later schema may hold kinds this version can't draw: those rows are left out below
        if let schema = object["schema"], (schema as? Int).map({ $0 < 1 }) ?? true { return nil }
        var seen = Set<String>()
        let settings = rows.compactMap { ($0 as? [String: Any]).flatMap(setting) }.filter {
            seen.insert($0.env).inserted
        }
        return LauncherSettings(titleID: object["game"] as? String, settings: settings)
    }

    private static func setting(_ row: [String: Any]) -> LauncherSetting? {
        guard let env = row["env"] as? String, env.wholeMatch(of: /[A-Z][A-Z0-9_]{0,63}/) != nil,
            let label = text(row["label"]), !label.isEmpty,
            let defaultValue = row["default"] as? String
        else { return nil }
        let kind: LauncherSetting.Kind
        switch row["kind"] as? String {
        case "choice":
            guard let raw = row["options"] as? [Any] else { return nil }
            let options = raw.compactMap { item -> LauncherSetting.Option? in
                guard let pair = item as? [Any], pair.count == 2, let value = pair[0] as? String,
                    let title = text(pair[1])
                else { return nil }
                return LauncherSetting.Option(value: value, label: title.isEmpty ? value : title)
            }
            guard !options.isEmpty else { return nil }
            kind = .choice(options)
        case "range":
            guard let min = number(row["min"]), let max = number(row["max"]),
                let step = number(row["step"]),
                min <= max, step > 0
            else { return nil }
            kind = .range(min: min, max: max, step: step)
        case "toggle":
            guard let on = row["on"] as? String, let off = row["off"] as? String, on != off else {
                return nil
            }
            kind = .toggle(on: on, off: off)
        default:
            return nil  // a kind this version doesn't know (schema 2)
        }
        let needs = (row["needs"] as? String).flatMap { needs -> LauncherSetting.Needs? in
            let parts = needs.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 && !parts[0].isEmpty
                ? LauncherSetting.Needs(env: parts[0], value: parts[1]) : nil
        }
        let setting = LauncherSetting(
            env: env, kind: kind,
            section: text(row["section"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Game",
            label: label, note: text(row["note"]) ?? "", defaultValue: defaultValue,
            isBasic: row["level"] as? String == "basic", needs: needs)
        // a default the row doesn't offer would make every choice look changed
        return setting.accepts(defaultValue) ? setting : nil
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON's true and false come as NSNumbers too
        guard let value, CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
            let number = (value as? NSNumber)?.doubleValue,
            number.isFinite
        else {
            return nil
        }
        return number
    }

    /// One line of text, at most 200 characters.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = String(
            text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
            }
        ).trimmingCharacters(in: .whitespaces)
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}
