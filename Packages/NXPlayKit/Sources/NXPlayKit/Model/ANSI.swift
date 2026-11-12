/// A terminal color: one of the 16 named ones, the 256-color palette, or 24-bit.
public enum ANSIColor: Hashable, Sendable, Codable {
    case standard(Int)  // 0–7 normal, 8–15 bright
    case palette(Int)  // 16–255 (0–15 are folded into .standard)
    case rgb(UInt8, UInt8, UInt8)

    static func indexed(_ n: Int) -> ANSIColor? {
        switch n {
        case 0...15: .standard(n)
        case 16...255: .palette(n)
        default: nil
        }
    }
}

/// The SGR state of the text: what `ESC[…m` sequences set.
public struct ANSIStyle: Hashable, Sendable, Codable {
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var foreground: ANSIColor?
    public var background: ANSIColor?

    public init() {}

    public var isPlain: Bool { self == ANSIStyle() }

    /// Applies one SGR sequence's parameters ("1;32", "38;5;208", "" = reset).
    mutating func apply(_ parameters: String) {
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }  // 38:5:208 as well as 38;5;208
            .map { Int($0) ?? 0 }[...]
        if codes.isEmpty { codes = [0] }
        while let code = codes.popFirst() {
            switch code {
            case 0: self = ANSIStyle()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 7: inverse = true
            case 22:
                bold = false
                dim = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 30...37: foreground = .standard(code - 30)
            case 39: foreground = nil
            case 40...47: background = .standard(code - 40)
            case 49: background = nil
            case 90...97: foreground = .standard(code - 90 + 8)
            case 100...107: background = .standard(code - 100 + 8)
            case 38, 48:
                let color = Self.extendedColor(&codes)
                if code == 38 {
                    foreground = color ?? foreground
                } else {
                    background = color ?? background
                }
            default: break  // blink, conceal, fonts…: not shown
            }
        }
    }

    /// `5;n` or `2;r;g;b` after a 38 / 48.
    private static func extendedColor(_ codes: inout ArraySlice<Int>) -> ANSIColor? {
        switch codes.popFirst() {
        case 5:
            return codes.popFirst().flatMap(ANSIColor.indexed)
        case 2:
            guard codes.count >= 3 else {
                codes.removeAll()
                return nil
            }
            let rgb = codes.prefix(3).map { UInt8(clamping: $0) }
            codes.removeFirst(3)
            return .rgb(rgb[0], rgb[1], rgb[2])
        default:
            return nil
        }
    }
}

/// A line of output without its escape sequences, and the styled pieces it is made of
/// (none when the line has no styling).
public struct LogLine: Hashable, Sendable, Codable {
    public struct Segment: Hashable, Sendable, Codable {
        public let text: String
        public let style: ANSIStyle
    }

    public let text: String
    public let segments: [Segment]

    public init(_ text: String) {
        self.text = text
        segments = []
    }

    /// A line from NX Play or nxplay itself, blue, set apart from nxnative's output (nxplay's say).
    static func own(_ text: String) -> LogLine {
        var style = ANSIStyle()
        style.foreground = .standard(4)
        return LogLine(segments: [Segment(text: text, style: style)])
    }

    init(segments: [Segment]) {
        let segments = segments.filter { !$0.text.isEmpty }
        text = segments.map(\.text).joined()
        self.segments = segments.allSatisfy(\.style.isPlain) ? [] : segments
    }
}

/// Turns terminal output into LogLines: SGR sequences become styles (carried from line to line, as a
/// terminal does), every other escape sequence (cursor moves, erase line, window titles) is dropped.
public struct ANSIParser: Sendable {
    public private(set) var style = ANSIStyle()

    public init() {}

    public mutating func parse(_ line: String) -> LogLine {
        guard line.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else {
            return style.isPlain
                ? LogLine(line) : LogLine(segments: [.init(text: line, style: style)])
        }
        var segments: [LogLine.Segment] = []
        var text = String.UnicodeScalarView()
        func flush() {
            if !text.isEmpty { segments.append(.init(text: String(text), style: style)) }
            text = String.UnicodeScalarView()
        }

        var scalars = line.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\u{1B}":
                switch scalars.popFirst() {
                case "[":  // CSI: parameters, then a final byte in @…~
                    var parameters = ""
                    while let next = scalars.popFirst() {
                        if (0x40...0x7E).contains(next.value) {
                            if next == "m" {
                                flush()
                                style.apply(parameters)
                            }
                            break
                        }
                        parameters.unicodeScalars.append(next)
                    }
                case "]":  // OSC: up to BEL or ESC \
                    while let next = scalars.popFirst() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}" {
                            _ = scalars.popFirst()
                            break
                        }
                    }
                default:
                    break  // a two-byte escape (ESC 7, ESC =, …)
                }
            case "\t":
                text.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                break  // BEL, backspace and the like
            default:
                text.append(scalar)
            }
        }
        flush()
        return LogLine(segments: segments)
    }
}
