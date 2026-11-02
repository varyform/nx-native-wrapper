import Foundation

/// Apps signed for development stop opening when their provisioning profile expires: 7 days after the install for
/// a Personal Team, a year for a paid one. Installing again from the Mac renews them.
enum Expiry {
    /// Within this, a game is flagged for renewal.
    static let warning: TimeInterval = 2 * 24 * 3600

    /// This app's own expiry, from the profile it was installed with.
    static let launcher: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static func isSoon(_ date: Date?, now: Date = .now) -> Bool {
        date.map { $0.timeIntervalSince(now) < warning } ?? false
    }

    /// "Expires in 3 days", "Expires today", "Expired"
    static func text(_ date: Date, now: Date = .now) -> String {
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "Expired" }
        let days = Int(left / 86_400)
        return days == 0 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")"
    }
}
