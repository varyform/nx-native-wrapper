import Foundation

/// An nxnative issue that names a game.
public struct NXNativeIssue: Codable, Hashable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let isOpen: Bool
    public let url: URL
    public var id: Int { number }
}

/// nxnative's GitHub issues about a game, found by its title ID: the place a failure is reported and fixed, often
/// already with a workaround. Asked only after a failure, of GitHub's public search, without an account; what leaves
/// the Mac is the title ID, a public number. Guarded, so a run of failures can't hammer GitHub or stall NX Play:
/// one answer per game an hour, one request every 10 seconds at most (the search allows 10 a minute without an
/// account), nothing until the time GitHub names after it refuses, and an 8-second limit on each request. Without an
/// answer, the card links to the same search on the web.
actor NXNativeIssues {
    static let shared = NXNativeIssues()

    /// The repository its issues are in: nxnative's, whichever fork or branch this Mac builds with.
    nonisolated static let repository = "seedds/nxnative"

    /// The web page of the same search, for when there's no answer (or more to see).
    nonisolated static func searchPage(titleID: String) -> URL {
        var parts = URLComponents(string: "https://github.com/\(repository)/issues")!
        parts.queryItems = [URLQueryItem(name: "q", value: "is:issue \(titleID.uppercased())")]
        return parts.url!
    }

    private var answers: [String: (at: Date, issues: [NXNativeIssue])] = [:]
    private var lastRequest: Date?
    private var refusedUntil: Date?
    private let session: URLSession
    private let now: @Sendable () -> Date

    static let answerLife: TimeInterval = 3600
    static let spacing: TimeInterval = 10
    static let refusalPause: TimeInterval = 600

    init(session: URLSession? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 8
            return URLSession(configuration: config)
        }()
        self.now = now
    }

    /// The issues naming the title ID, open ones first; nil when GitHub can't be asked now (offline, refused, too soon
    /// after the last request) or didn't answer.
    func issues(titleID: String) async -> [NXNativeIssue]? {
        let id = titleID.uppercased()
        let time = now()
        if let answer = answers[id], time.timeIntervalSince(answer.at) < Self.answerLife { return answer.issues }
        if let until = refusedUntil, time < until { return nil }
        if let last = lastRequest, time.timeIntervalSince(last) < Self.spacing { return nil }
        lastRequest = time
        guard let (data, response) = try? await session.data(for: Self.request(titleID: id)),
            let http = response as? HTTPURLResponse
        else { return nil }
        guard http.statusCode == 200 else {
            // 403 / 429: the limit; GitHub names when it lifts. Anything else: a pause all the same
            refusedUntil = Self.retryTime(http, now: now()) ?? now().addingTimeInterval(Self.refusalPause)
            return nil
        }
        guard let found = Self.parse(data) else { return nil }
        answers[id] = (now(), found)
        return found
    }

    nonisolated static func request(titleID: String) -> URLRequest {
        var parts = URLComponents(string: "https://api.github.com/search/issues")!
        parts.queryItems = [
            URLQueryItem(name: "q", value: "repo:\(repository) is:issue \(titleID)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: "10"),
        ]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // a generic client name: nothing about the player
        request.setValue("NXPlay", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Retry-After's seconds, else X-RateLimit-Reset's time.
    nonisolated static func retryTime(_ response: HTTPURLResponse, now: Date) -> Date? {
        if let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return now.addingTimeInterval(after)
        }
        return response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map {
            Date(timeIntervalSince1970: $0)
        }
    }

    /// The search's items, open ones first, each kept to what the card shows.
    nonisolated static func parse(_ data: Data) -> [NXNativeIssue]? {
        struct Page: Decodable {
            struct Item: Decodable {
                /// Present on a pull request, which the search returns too unless told not to.
                struct PullRequest: Decodable {}
                let number: Int
                let title: String
                let state: String
                let html_url: URL
                let pull_request: PullRequest?
            }
            let items: [Item]
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        let issues = page.items.filter { $0.pull_request == nil }.map {
            NXNativeIssue(number: $0.number, title: $0.title, isOpen: $0.state == "open", url: $0.html_url)
        }
        return issues.filter(\.isOpen) + issues.filter { !$0.isOpen }
    }
}
