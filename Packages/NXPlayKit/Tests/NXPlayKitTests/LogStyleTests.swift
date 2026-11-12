import AppKit
import Testing

@testable import NXPlayKit

/// The colour the log gives a line from what it says.
@MainActor @Suite struct LogStyleTests {
    func color(_ line: String) -> NSColor? {
        LogStyle.attributes(for: line)[.foregroundColor] as? NSColor
    }

    @Test func aCommitQuotingAProblemIsNotOne() {
        #expect(color("[13:57:00] [RED] 3 file(s) could not be read") == .systemRed)
        #expect(color("  ed323824 CI passes again: a hang reports \"[RED] the host has waited 10 s\"") == .labelColor)
        #expect(color("  e6048dea A stage ends with ✗ (seedds, 2 days ago)") == .labelColor)
        #expect(color("  not a hash [RED]") == .systemRed)
    }
}
