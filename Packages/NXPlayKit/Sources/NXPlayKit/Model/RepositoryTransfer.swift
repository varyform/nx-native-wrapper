import Foundation

/// One HTTP GET for Sources: a catalog read into memory (with a size limit), or a game file streamed into an open file
/// with its checksum (the algorithm its catalog names) worked out as the bytes arrive, so a file of many gigabytes is
/// never held in memory or read twice.
/// Only a 200 counts. A source's token goes only to its own origin: a redirect elsewhere, or to plain http from https,
/// loses it (or is refused). No cookies, cache or saved credentials. Cancelling the calling task stops the transfer.
final class RepositoryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Sink {
        case memory(limit: Int)
        case file(FileHandle, expected: Int64, algorithm: Checksum.Algorithm)
    }

    static let maxRedirects = 5

    private let request: URLRequest
    private let auth: SourceAuth?
    private let sink: Sink
    private let progress: (@Sendable (Int64) -> Void)?
    /// Delegate calls run here, one at a time: they own the state below.
    private let queue: OperationQueue
    private var buffer = Data()
    private var received: Int64 = 0
    private var reported: (bytes: Int64, at: Date) = (0, .distantPast)
    private var hasher: Checksum.Hasher
    private var failure: Failure?
    private var redirects = 0
    /// Where the answer came from: the request's address, or the last redirect's (each one checked on the way).
    private var finalURL: URL
    private var continuation: CheckedContinuation<(Data, Checksum, URL), any Error>?
    /// Cancellation can come from any thread, before the task starts too.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(url: URL, auth: SourceAuth?, sink: Sink, progress: (@Sendable (Int64) -> Void)?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        if let header = auth?.header(for: url) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        if case .file = sink {
            // the bytes counted and hashed are the file's, not a compressed form of it
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        request.setValue("NX Play", forHTTPHeaderField: "User-Agent")
        self.request = request
        finalURL = url
        self.auth = auth
        self.sink = sink
        self.progress = progress
        if case .file(_, _, let algorithm) = sink {
            hasher = Checksum.Hasher(algorithm)
        } else {
            hasher = Checksum.Hasher(.sha256)  // a catalog's checksum isn't checked; it's never read
        }
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
    }

    /// The body of `url`, refused past `limit` bytes, and the address it came from after any redirects: what the
    /// catalog's relative file addresses resolve against.
    static func data(from url: URL, auth: SourceAuth?, limit: Int) async throws -> (data: Data, url: URL) {
        let (data, _, final) = try await RepositoryTransfer(
            url: url, auth: auth, sink: .memory(limit: limit), progress: nil
        ).run()
        return (data, final)
    }

    /// Streams `url` into `file`; its checksum by `algorithm` once exactly `expected` bytes have arrived. `progress`
    /// hears the bytes so far, a few times a second.
    static func download(
        from url: URL, auth: SourceAuth?, into file: FileHandle, expected: Int64, algorithm: Checksum.Algorithm,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Checksum {
        try await RepositoryTransfer(
            url: url, auth: auth, sink: .file(file, expected: expected, algorithm: algorithm), progress: progress
        ).run().1
    }

    private func run() async throws -> (Data, Checksum, URL) {
        if let problem = RepositoryAddress.problem(with: request.url!) {
            throw Failure(message: problem)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // the longest wait for the next bytes; a whole file may take hours on a slow link
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 86_400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    self.continuation = continuation
                    let task = session.dataTask(with: self.request)
                    let stop = self.lock.withLock {
                        self.task = task
                        return self.cancelled
                    }
                    if stop {
                        self.finish(.failure(CancellationError()))
                    } else {
                        task.resume()
                    }
                }
            }
        } onCancel: {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private func finish(_ result: Result<(Data, Checksum, URL), any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    /// Stops the transfer with `message`, the reason the caller hears.
    private func fail(_ message: String, _ task: URLSessionTask) {
        if failure == nil { failure = Failure(message: message) }
        task.cancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        redirects += 1
        guard let url = newRequest.url else { return completionHandler(nil) }
        if redirects > Self.maxRedirects {
            fail("Too many redirects", task)
            return completionHandler(nil)
        }
        if let problem = RepositoryAddress.problem(with: url) {
            fail("A redirect went to \(url.host() ?? "another address"): \(problem)", task)
            return completionHandler(nil)
        }
        if response.url?.scheme?.lowercased() == "https", url.scheme?.lowercased() != "https" {
            fail("A redirect went from https to plain http", task)
            return completionHandler(nil)
        }
        finalURL = url
        var next = newRequest
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        if let header = auth?.header(for: url) {
            next.setValue(header, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let hint =
                status == 401 || status == 403
                ? ": the source needs an access token, or another one" : ""
            fail("The server answered \(status)\(hint)", dataTask)
            return completionHandler(.cancel)
        }
        let length = response.expectedContentLength
        switch sink {
        case .memory(let limit) where length > Int64(limit):
            fail("The catalog is larger than \(limit / 1024 / 1024) MB", dataTask)
            return completionHandler(.cancel)
        case .file(_, let expected, _) where length >= 0 && length != expected:
            fail(
                "The server's file is \(length) bytes; the catalog says \(expected): the catalog is out of date",
                dataTask)
            return completionHandler(.cancel)
        default:
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        switch sink {
        case .memory(let limit):
            guard received <= Int64(limit) else {
                return fail("The catalog is larger than \(limit / 1024 / 1024) MB", dataTask)
            }
            buffer.append(data)
        case .file(let handle, let expected, _):
            guard received <= expected else {
                return fail("The server sent more than the catalog's \(expected) bytes", dataTask)
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                return fail("Couldn't write the file: \(error.localizedDescription)", dataTask)
            }
            hasher.update(data: data)
            let now = Date()
            if received == expected
                || (received - reported.bytes >= 1 << 20 && now.timeIntervalSince(reported.at) >= 0.25)
            {
                reported = (received, now)
                progress?(received)
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        if let failure { return finish(.failure(failure)) }
        if let error {
            let stopped = lock.withLock { cancelled }
            return finish(
                .failure(stopped ? CancellationError() : Failure(message: error.localizedDescription)))
        }
        if case .file(_, let expected, _) = sink, received != expected {
            return finish(
                .failure(
                    Failure(message: "The download ended after \(received) of \(expected) bytes")))
        }
        finish(.success((buffer, hasher.finalize(), finalURL)))
    }
}
