import Foundation

/// Speed test using macOS's built-in `networkQuality` tool, which tests against Apple's CDN.
/// It only reports results at the end, so progress is estimated from elapsed time.
struct NetworkQualityEngine: Sendable {
    static let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    /// Passed as `-M`; each run takes about half a second longer than this.
    var maxRuntime = 10

    struct Measurement {
        var mbps: Double
        var latency: LatencyResult?
    }

    func measure(_ kind: TransferKind, progress: @escaping @Sendable @MainActor (Double) -> Void) async throws -> Measurement {
        try Task.checkCancellation()
        let output = FileManager.default.temporaryDirectory
            .appending(path: "networkQuality-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }

        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = Self.executable
        // -u skips upload, -d skips download.
        process.arguments = [kind == .download ? "-u" : "-d", "-M", String(maxRuntime), "-c"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let runner = ProcessRunner(process)

        let expected = Double(maxRuntime) + 0.5
        let ticker = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                progress(min(Date().timeIntervalSince(start) / expected, 0.97))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { ticker.cancel() }

        // -M doesn't cover fetching the test configuration, which can hang on a bad network.
        let watchdog = Task { [maxRuntime] in
            try await Task.sleep(for: .seconds(maxRuntime + 10))
            runner.terminate()
        }
        defer { watchdog.cancel() }

        try await withTaskCancellationHandler {
            try await runner.run()
        } onCancel: {
            runner.cancel()
        }

        try Task.checkCancellation()
        guard process.terminationStatus == 0,
              let report = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: output))
        else {
            throw NetworkQualityError.failed(code: nil)
        }
        // On failure the tool still exits 0, with an error code and no throughput.
        guard let bitsPerSecond = kind == .download ? report.dl_throughput : report.ul_throughput else {
            throw NetworkQualityError.failed(code: report.error_code)
        }

        // A TCP handshake takes exactly one round trip, which makes it a clean ping sample.
        let latency = LatencyResult(samples: report.il_tcp_handshake_443 ?? [])
            ?? report.base_rtt.flatMap { LatencyResult(samples: [$0]) }
        return Measurement(mbps: bitsPerSecond / 1_000_000, latency: latency)
    }

    private struct Report: Decodable {
        let dl_throughput: Double?
        let ul_throughput: Double?
        let base_rtt: Double?
        let il_tcp_handshake_443: [Double]?
        let error_code: Int?
    }
}

/// Runs a process to completion; a cancel that arrives before launch prevents the launch.
private final class ProcessRunner: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false

    init(_ process: Process) {
        self.process = process
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func terminate() {
        lock.withLock {
            if process.isRunning { process.terminate() }
        }
    }
}

enum NetworkQualityError: LocalizedError {
    /// `code` is the URL error the tool reports in its JSON, if any.
    case failed(code: Int?)

    var errorDescription: String? {
        switch self {
        case .failed(code: NSURLErrorNotConnectedToInternet?):
            return "You appear to be offline."
        case .failed(code: NSURLErrorTimedOut?):
            return "Apple's speed test timed out. Check your connection and try again."
        case .failed:
            return "Apple's networkQuality test failed. Check your connection and try again."
        }
    }
}
