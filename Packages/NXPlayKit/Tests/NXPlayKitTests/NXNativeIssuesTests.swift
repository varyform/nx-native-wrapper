import Foundation
import Testing

@testable import NXPlayKit

/// GitHub's answers, made up: each test's own, by the session's identifier.
final class IssuesStub: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }
    nonisolated(unsafe) static var answers: [String: Answer] = [:]
    nonisolated(unsafe) static var requests: [String: Int] = [:]
    static let lock = NSLock()

    static func session(_ key: String, _ answer: Answer) -> URLSession {
        lock.withLock {
            answers[key] = answer
            requests[key] = 0
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IssuesStub.self]
        config.httpAdditionalHeaders = ["X-Test": key]
        return URLSession(configuration: config)
    }
    static func count(_ key: String) -> Int { lock.withLock { requests[key] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Test") ?? ""
        let answer = Self.lock.withLock {
            Self.requests[key, default: 0] += 1
            return Self.answers[key] ?? Answer(status: 500)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

struct NXNativeIssuesTests {
    static let page = Data(
        """
        {"items": [
          {"number": 3010, "title": "game: Ocarina of Time drops a stray BAHS entry", "state": "closed",
           "html_url": "https://github.com/seedds/nxnative/pull/3010", "pull_request": {"url": "x"}},
          {"number": 2920, "title": "Ocarina of Time: green blocks", "state": "closed",
           "html_url": "https://github.com/seedds/nxnative/issues/2920"},
          {"number": 2825, "title": "Ocarina of Time: start aborts", "state": "open",
           "html_url": "https://github.com/seedds/nxnative/issues/2825"}
        ]}
        """.utf8)

    @Test func issuesOnlyOpenOnesFirst() throws {
        let issues = try #require(NXNativeIssues.parse(Self.page))
        #expect(issues.map(\.number) == [2825, 2920])
        #expect(issues.map(\.isOpen) == [true, false])
    }

    @Test func onlyTheTitleIDIsAsked() throws {
        let url = try #require(NXNativeIssues.request(titleID: "0400486024DEC000").url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host == "api.github.com")
        #expect(query.first { $0.name == "q" }?.value == "repo:seedds/nxnative is:issue 0400486024DEC000")
    }

    @Test func anAnswerIsKeptAnHour() async throws {
        let clock = TestClock()
        let issues = NXNativeIssues(
            session: IssuesStub.session("hour", .init(body: Self.page)), now: { clock.now })
        #expect(await issues.issues(titleID: "0400486024DEC000")?.count == 2)
        clock.advance(1800)
        #expect(await issues.issues(titleID: "0400486024dec000")?.count == 2)
        #expect(IssuesStub.count("hour") == 1)
        clock.advance(1801)
        _ = await issues.issues(titleID: "0400486024DEC000")
        #expect(IssuesStub.count("hour") == 2)
    }

    @Test func requestsAreSpacedOut() async throws {
        let clock = TestClock()
        let issues = NXNativeIssues(
            session: IssuesStub.session("spacing", .init(body: Self.page)), now: { clock.now })
        _ = await issues.issues(titleID: "0100000000001000")
        // another game, too soon after: no request, no answer
        #expect(await issues.issues(titleID: "0100000000002000") == nil)
        #expect(IssuesStub.count("spacing") == 1)
        clock.advance(NXNativeIssues.spacing)
        #expect(await issues.issues(titleID: "0100000000002000") != nil)
        #expect(IssuesStub.count("spacing") == 2)
    }

    @Test func aRefusalPausesUntilGitHubSays() async throws {
        let clock = TestClock()
        let issues = NXNativeIssues(
            session: IssuesStub.session("refused", .init(status: 403, headers: ["Retry-After": "120"])),
            now: { clock.now })
        #expect(await issues.issues(titleID: "0100000000001000") == nil)
        clock.advance(60)
        #expect(await issues.issues(titleID: "0100000000001000") == nil)
        #expect(IssuesStub.count("refused") == 1)
        clock.advance(61)
        _ = await issues.issues(titleID: "0100000000001000")
        #expect(IssuesStub.count("refused") == 2)
    }
}
