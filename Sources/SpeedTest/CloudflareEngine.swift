import Foundation

enum SpeedTestError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval?)
    /// Automatic mode only: the next test will go to Apple.
    case rateLimitedDuringTest
    case httpStatus(Int)
    /// Requests succeed but carry no data, e.g. a captive portal or a proxy in the way.
    case emptyResponses

    init?(_ response: HTTPURLResponse) {
        switch response.statusCode {
        case 200..<300:
            return nil
        case 429:
            self = .rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Self.parseRetryAfter))
        default:
            self = .httpStatus(response.statusCode)
        }
    }

    /// `Retry-After` is either seconds ("3425") or an HTTP date ("Wed, 21 Oct 2026 07:28:00 GMT").
    private static func parseRetryAfter(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSinceNow, 0) }
    }

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            guard let retryAfter, retryAfter > 0 else {
                return "Cloudflare rate limit reached. Try again later."
            }
            let minutes = Int((retryAfter / 60).rounded(.up))
            return "Cloudflare rate limit reached. Try again in \(minutes) min."
        case .rateLimitedDuringTest:
            return "Cloudflare started rate-limiting during the test. Test again to use Apple."
        case .httpStatus(let code):
            return "The speed test server returned an error (HTTP \(code))."
        case .emptyResponses:
            return "The speed test server sent no data. A captive portal or proxy may be in the way."
        }
    }
}

/// Speed test against Cloudflare's public endpoints (speed.cloudflare.com).
struct CloudflareEngine: Sendable {
    static let baseURL = URL(string: "https://speed.cloudflare.com")!

    /// 25 MB is the largest size Cloudflare's own test requests; 100 MB is refused.
    var downloadChunkBytes = 25_000_000
    var uploadChunkBytes = 10_000_000
    var parallelStreams = 6
    /// Bytes moved during the first seconds are ignored (TCP slow start).
    var warmupSeconds = 1.5

    // MARK: Availability

    /// Requests one download chunk and reads only the status line, so a rate limit
    /// is detected before the test starts. Throws `SpeedTestError` on a non-2xx status.
    func checkAvailability() async throws {
        let session = URLSession(configuration: Self.configuration(streams: 1))
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: Self.downloadURL(bytes: downloadChunkBytes)))
        bytes.task.cancel()
        if let http = response as? HTTPURLResponse, let error = SpeedTestError(http) {
            throw error
        }
    }

    // MARK: Latency

    func measureLatency(samples: Int = 12) async throws -> LatencyResult {
        let session = URLSession(configuration: Self.configuration(streams: 1))
        defer { session.invalidateAndCancel() }

        var serverRTTs: [Double] = []
        var clientTimes: [Double] = []
        var server: String?

        // The first request opens the connection and is discarded.
        for i in 0...samples {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            let (_, response) = try await session.data(for: URLRequest(url: Self.downloadURL(bytes: 0)))
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            guard let http = response as? HTTPURLResponse else { continue }
            if let error = SpeedTestError(http) { throw error }
            if i == 0 {
                server = Self.colo(from: http)
                continue
            }
            if let rtt = Self.serverRTT(from: http) { serverRTTs.append(rtt) }
            clientTimes.append(elapsedMs)
        }

        // The server's TCP RTT excludes Cloudflare's request processing time,
        // so prefer it; client timings are a fallback if the header goes away.
        let times = serverRTTs.count == clientTimes.count ? serverRTTs : clientTimes
        guard let result = LatencyResult(samples: times, server: server) else {
            throw URLError(.badServerResponse)
        }
        return result
    }

    // MARK: Throughput

    /// Saturates the link with parallel streams for `duration` seconds.
    /// `progress` receives (fraction complete, current Mbps) about 10 times per second.
    /// Returns the average Mbps after warm-up.
    func measure(
        _ kind: TransferKind,
        duration: TimeInterval,
        progress: @escaping @Sendable @MainActor (Double, Double) -> Void
    ) async throws -> Double {
        let payload = kind == .upload ? Data(count: uploadChunkBytes) : Data()
        let downloadBytes = downloadChunkBytes
        let meter = TransferMeter(countsReceivedData: kind == .download) { session in
            switch kind {
            case .download:
                return session.dataTask(with: URLRequest(url: Self.downloadURL(bytes: downloadBytes)))
            case .upload:
                var request = URLRequest(url: Self.uploadURL)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                return session.uploadTask(with: request, from: payload)
            }
        }

        let session = URLSession(
            configuration: Self.configuration(streams: parallelStreams),
            delegate: meter,
            delegateQueue: nil
        )
        defer {
            meter.stop()
            session.invalidateAndCancel()
        }

        meter.start(session, streams: parallelStreams)

        let start = ProcessInfo.processInfo.systemUptime
        var samples: [(time: Double, bytes: Int64)] = [(0, 0)]
        var warmupSample: (time: Double, bytes: Int64)?

        while true {
            try await Task.sleep(for: .milliseconds(100))
            let t = ProcessInfo.processInfo.systemUptime - start
            let bytes = meter.bytes
            samples.append((t, bytes))
            if warmupSample == nil, t >= warmupSeconds {
                warmupSample = (t, bytes)
            }

            // Live speed over a sliding one-second window.
            let windowStart = samples.last(where: { $0.time <= t - 1.0 }) ?? samples[0]
            let current = Self.mbps(bytes: bytes - windowStart.bytes, seconds: t - windowStart.time)
            await progress(min(t / duration, 1), current)

            if t >= duration { break }
            if let error = meter.httpError ?? meter.fatalError { throw error }
        }

        let last = samples[samples.count - 1]
        if let error = meter.httpError { throw error }
        guard last.bytes > 0 else { throw meter.fatalError ?? URLError(.notConnectedToInternet) }
        let from = warmupSample ?? samples[0]
        return Self.mbps(bytes: last.bytes - from.bytes, seconds: last.time - from.time)
    }

    // MARK: Helpers

    private static func configuration(streams: Int) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = streams
        config.timeoutIntervalForRequest = 15
        return config
    }

    private static func downloadURL(bytes: Int) -> URL {
        baseURL.appending(path: "__down").appending(queryItems: [URLQueryItem(name: "bytes", value: String(bytes))])
    }

    private static var uploadURL: URL { baseURL.appending(path: "__up") }

    private static func mbps(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Cloudflare reports the connection's TCP RTT in microseconds,
    /// e.g. `server-timing: cfL4;desc="?proto=TCP&rtt=8538&min_rtt=8504…"`. Returns milliseconds.
    private static func serverRTT(from response: HTTPURLResponse) -> Double? {
        guard let header = response.value(forHTTPHeaderField: "Server-Timing"),
              let range = header.range(of: #"[?&]rtt=[0-9]+"#, options: .regularExpression),
              let micros = Double(header[range].drop(while: { $0 != "=" }).dropFirst())
        else { return nil }
        return micros / 1000
    }

    /// The data center code is the suffix of the `cf-ray` header, e.g. `8a1b2c3d4e-GRU`.
    private static func colo(from response: HTTPURLResponse) -> String? {
        guard let ray = response.value(forHTTPHeaderField: "cf-ray"),
              let code = ray.split(separator: "-").last, code.count == 3
        else { return nil }
        return String(code)
    }
}

/// Counts bytes moving through a URLSession and keeps every stream busy until stopped.
private final class TransferMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let makeTask: (URLSession) -> URLSessionTask
    private let countsReceivedData: Bool
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _stopped = false
    private var _consecutiveFailures = 0
    private var _lastError: Error?
    private var _httpError: SpeedTestError?

    /// Consecutive failed requests across all streams before the test gives up.
    private static let maxFailures = 10
    /// A request that moved less than this was not a real transfer (e.g. a proxy's empty reply).
    private static let minUsefulBytes: Int64 = 64_000
    /// Pause before replacing a failed request, so a broken server isn't hit in a tight loop.
    private static let retryDelay: TimeInterval = 0.2

    init(countsReceivedData: Bool, makeTask: @escaping (URLSession) -> URLSessionTask) {
        self.countsReceivedData = countsReceivedData
        self.makeTask = makeTask
    }

    var bytes: Int64 { lock.withLock { _bytes } }

    /// Set once requests keep failing, so the caller can give up instead of reporting a partial result.
    var fatalError: Error? {
        lock.withLock { _consecutiveFailures >= Self.maxFailures ? _lastError : nil }
    }

    /// A non-2xx response (e.g. 429 rate limit). Retrying would only make it worse, so it stops the test.
    var httpError: SpeedTestError? { lock.withLock { _httpError } }

    /// Once this returns, no new task is created, so the session can be invalidated safely.
    func stop() { lock.withLock { _stopped = true } }

    func start(_ session: URLSession, streams: Int) {
        lock.withLock {
            for _ in 0..<streams { makeTask(session).resume() }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let error = SpeedTestError(http) else {
            completionHandler(.allow)
            return
        }
        lock.withLock { _httpError = error }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard countsReceivedData else { return }
        lock.withLock { _bytes += Int64(data.count) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard !countsReceivedData else { return }
        lock.withLock { _bytes += bytesSent }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let moved = countsReceivedData ? task.countOfBytesReceived : task.countOfBytesSent
        let failed = error != nil || moved < Self.minUsefulBytes

        let retryNow: Bool = lock.withLock {
            if failed {
                _consecutiveFailures += 1
                _lastError = error ?? SpeedTestError.emptyResponses
            } else {
                _consecutiveFailures = 0
            }
            guard canRestart else { return false }
            if !failed {
                // Created under the lock so stop() can't slip in before the session is invalidated.
                makeTask(session).resume()
            }
            return failed
        }

        if retryNow {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
                lock.withLock {
                    if canRestart { makeTask(session).resume() }
                }
            }
        }
    }

    /// Call with the lock held.
    private var canRestart: Bool {
        !_stopped && _httpError == nil && _consecutiveFailures < Self.maxFailures
    }
}
