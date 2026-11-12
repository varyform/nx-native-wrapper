import AppKit
import SwiftUI

/// A read-only text view that appends only the new lines of a log (a game can print thousands),
/// and follows the end unless scrolled up.
struct LogTextView: NSViewRepresentable {
    let jobID: UUID
    let log: LogBuffer

    final class Coordinator {
        var jobID: UUID?
        var shown = 0
        var dropped = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.font = LogStyle.font
            text.textContainerInset = NSSize(width: 8, height: 6)
            text.backgroundColor = .textBackgroundColor
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else {
            return
        }
        let state = context.coordinator
        let reload =
            state.jobID != jobID
            || state.shown < log.dropped
            || state.shown > log.total
            || log.dropped - state.dropped > log.limit / 4  // lines dropped from the buffer: drop them here too
        if reload {
            storage.setAttributedString(NSAttributedString())
            state.jobID = jobID
            state.dropped = log.dropped
            state.shown = log.dropped
        }
        let start = state.shown - log.dropped
        guard start < log.lines.count else { return }

        let follow = reload || isAtEnd(scroll)
        let chunk = NSMutableAttributedString()
        for line in log.lines[start...] {
            let base = LogStyle.attributes(for: line.text)
            if storage.length + chunk.length > 0 {
                chunk.append(NSAttributedString(string: "\n", attributes: base))
            }
            if line.segments.isEmpty {
                chunk.append(NSAttributedString(string: line.text, attributes: base))
            } else {
                for segment in line.segments {
                    chunk.append(
                        NSAttributedString(
                            string: segment.text,
                            attributes: LogStyle.attributes(segment.style, over: base)))
                }
            }
        }
        storage.beginEditing()
        storage.append(chunk)
        storage.endEditing()
        state.shown = log.total
        if follow { text.scrollToEndOfDocument(nil) }
    }

    private func isAtEnd(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        return scroll.contentView.bounds.maxY >= document.frame.height - 30
    }
}

@MainActor
enum LogStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    /// build_ipa_from_nsp.py marks problems with [RED] and stage ends with ✓ / ✗.
    static func attributes(for line: String) -> [NSAttributedString.Key: Any] {
        let color: NSColor =
            if isCommit(line) {
                .labelColor  // nxplay's list of new nxnative commits: a subject can quote "[RED]" or "✗"
            } else if line.contains("[RED]") || line.contains("✗") || line.hasPrefix("nxplay: failed")
                || line.hasPrefix("Traceback")
            {
                .systemRed
            } else if line.contains("✓") || line.hasPrefix("nxplay: done") {
                .systemGreen
            } else if line.hasPrefix("$ ") || line.hasPrefix("nxplay:") {
                .secondaryLabelColor
            } else {
                .labelColor
            }
        return [.font: font, .foregroundColor: color]
    }

    /// "  <short hash> <subject>", as nxplay lists the commits an nxnative update brought.
    static func isCommit(_ line: String) -> Bool {
        line.wholeMatch(of: /\ \ [0-9a-f]{7,40} .*/) != nil
    }

    /// A terminal style on top of a line's own color: an ANSI color wins over it.
    static func attributes(_ style: ANSIStyle, over base: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any]
    {
        var attributes = base
        var foreground =
            style.foreground.map(color) ?? (base[.foregroundColor] as? NSColor ?? .labelColor)
        var background = style.background.map(color)
        if style.inverse {
            (foreground, background) = (background ?? .textBackgroundColor, foreground)
        }
        if style.dim { foreground = foreground.withAlphaComponent(0.6) }
        attributes[.foregroundColor] = foreground
        if let background { attributes[.backgroundColor] = background }
        var font = style.bold ? boldFont : self.font
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.font] = font
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    /// The 16 named colors follow the system palette (readable in light and dark mode);
    /// the 256-color cube and 24-bit colors are exact.
    static func color(_ color: ANSIColor) -> NSColor {
        switch color {
        case .standard(let n):
            return switch n % 8 {
            case 0: n < 8 ? .secondaryLabelColor : .systemGray
            case 1: .systemRed
            case 2: .systemGreen
            case 3: .systemYellow
            case 4: .systemBlue
            case 5: .systemPurple
            case 6: .systemCyan
            default: .labelColor
            }
        case .palette(let n) where n >= 232:
            let level = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        case .palette(let n):
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            let cube = n - 16
            return NSColor(
                srgbRed: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255,
                blue: levels[cube % 6] / 255, alpha: 1)
        case .rgb(let r, let g, let b):
            return NSColor(
                srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1
            )
        }
    }
}
