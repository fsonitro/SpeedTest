import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, latency, download, upload, finished, cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var uploadProgress = 0.0
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var pingMs: Double?
    @Published private(set) var jitterMs: Double?
    /// "Cloudflare · AMS" or "Apple" for the test in progress or just finished.
    @Published private(set) var serverLabel: String?
    @Published private(set) var networkInfo: NetworkInfo?
    @Published private(set) var networkInfoFailed = false
    @Published private(set) var history: [SpeedTestResult] = []
    @Published private(set) var nextAutoTest: Date?
    @Published private(set) var notificationsDenied = false
    @Published private(set) var launchAtLoginError: String?

    @Published var notifyOnFinish: Bool {
        didSet {
            defaults.set(notifyOnFinish, forKey: Keys.notify)
            guard notifyOnFinish else { return }
            Notifier.requestAuthorization { [weak self] granted in
                self?.notificationsDenied = !granted
                if !granted { self?.notifyOnFinish = false }
            }
        }
    }

    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var showIPAddress: Bool {
        didSet {
            defaults.set(showIPAddress, forKey: Keys.showIP)
            if showIPAddress {
                refreshNetworkInfo()
            } else {
                networkInfoTask?.cancel()
                networkInfo = nil
                networkInfoFailed = false
            }
        }
    }

    /// Set when Cloudflare answers 429, so Automatic goes straight to Apple until it expires.
    @Published private(set) var cloudflareBlockedUntil: Date? {
        didSet {
            defaults.set(cloudflareBlockedUntil, forKey: Keys.blockedUntil)
            scheduleBlockExpiry()
        }
    }

    var isCloudflareBlocked: Bool {
        (cloudflareBlockedUntil ?? .distantPast) > Date()
    }

    @Published var autoTestMinutes: Int {
        didSet {
            defaults.set(autoTestMinutes, forKey: Keys.autoTest)
            scheduleAutoTest()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
    }

    var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Login items point at this copy of the app, and ad-hoc builds change identity on every rebuild.
    var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    var isRunning: Bool {
        [.latency, .download, .upload].contains(phase)
    }

    var lastResult: SpeedTestResult? { history.first }

    /// Live numbers while testing, otherwise the last result.
    var menuBarText: String? {
        switch phase {
        case .latency:
            return "…"
        case .download:
            return "↓ \(downloadMbps.map(SpeedFormat.mbps) ?? "…")"
        case .upload:
            return "↑ \(uploadMbps.map(SpeedFormat.mbps) ?? "…")"
        default:
            guard let last = lastResult else { return nil }
            return "↓ \(SpeedFormat.mbps(last.downloadMbps)) ↑ \(SpeedFormat.mbps(last.uploadMbps))"
        }
    }

    private enum Keys {
        static let history = "history"
        static let notify = "notifyOnFinish"
        static let autoTest = "autoTestMinutes"
        static let provider = "provider"
        static let showIP = "showIPAddress"
        static let blockedUntil = "cloudflareBlockedUntil"
    }

    static let historyLimit = 50
    /// Wi-Fi usually needs a moment to reconnect after the Mac wakes.
    private static let wakeGracePeriod: TimeInterval = 30

    private let defaults = UserDefaults.standard
    private let cloudflare = CloudflareEngine()
    private let apple = NetworkQualityEngine()
    private var testTask: Task<Void, Never>?
    /// Identifies the current test; a task whose ID no longer matches must not touch state.
    private var runID = UUID()
    private var autoTestTask: Task<Void, Never>?
    private var blockExpiryTask: Task<Void, Never>?
    private var networkInfoTask: Task<Void, Never>?
    private var networkInfoGeneration = 0
    private var lastWake = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        notifyOnFinish = defaults.bool(forKey: Keys.notify)
        autoTestMinutes = defaults.integer(forKey: Keys.autoTest)
        provider = defaults.string(forKey: Keys.provider).flatMap(Provider.init) ?? .automatic
        showIPAddress = defaults.object(forKey: Keys.showIP) as? Bool ?? true
        cloudflareBlockedUntil = defaults.object(forKey: Keys.blockedUntil) as? Date
        if let data = defaults.data(forKey: Keys.history) {
            history = .decodeLossy(from: data)
        }
        Notifier.configure()
        observeSystemEvents()
        scheduleAutoTest()
        scheduleBlockExpiry()
        refreshNetworkInfo()
    }

    // MARK: Test

    func start() {
        guard !isRunning else { return }
        let id = UUID()
        runID = id
        resetLiveValues()
        // Set synchronously so a second start() (double click, auto-test) sees the test running.
        phase = .latency
        refreshNetworkInfo()
        // The next automatic test is one full interval after this one.
        scheduleAutoTest()
        testTask = Task { await run(id) }
    }

    func cancel() {
        guard isRunning else { return }
        testTask?.cancel()
        // Detach the old task right away, so a new test can start before it finishes unwinding.
        runID = UUID()
        resetLiveValues()
        phase = .cancelled
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func resetLiveValues() {
        downloadProgress = 0
        uploadProgress = 0
        downloadMbps = nil
        uploadMbps = nil
        pingMs = nil
        jitterMs = nil
        serverLabel = nil
    }

    private func run(_ id: UUID) async {
        do {
            let result = try await runChosenProvider(id)
            try ensureCurrent(id)
            history.insert(result, at: 0)
            history = Array(history.prefix(Self.historyLimit))
            saveHistory()
            phase = .finished

            if notifyOnFinish { Notifier.post(result) }
        } catch {
            guard runID == id else { return }
            if Task.isCancelled {
                resetLiveValues()
                phase = .cancelled
            } else {
                // Keep what completed (e.g. ping); blank out the transfer that didn't.
                if downloadProgress < 1 {
                    downloadProgress = 0
                    downloadMbps = nil
                }
                if uploadProgress < 1 {
                    uploadProgress = 0
                    uploadMbps = nil
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Throws if this test was cancelled or replaced while it was suspended.
    private func ensureCurrent(_ id: UUID) throws {
        if runID != id || Task.isCancelled { throw CancellationError() }
    }

    /// Each test runs on exactly one provider. Automatic decides up front, so a test
    /// never shows Cloudflare progress and then starts over on Apple.
    private func runChosenProvider(_ id: UUID) async throws -> SpeedTestResult {
        if provider == .apple || (provider == .automatic && isCloudflareBlocked) {
            return try await runApple(id)
        }

        if provider == .automatic {
            do {
                try await cloudflare.checkAvailability()
                try ensureCurrent(id)
            } catch SpeedTestError.rateLimited(let retryAfter) {
                try ensureCurrent(id)
                markCloudflareBlocked(retryAfter: retryAfter)
                return try await runApple(id)
            }
        }

        do {
            return try await runCloudflare(id)
        } catch SpeedTestError.rateLimited(let retryAfter) {
            try ensureCurrent(id)
            // Rate-limited partway through: stop rather than re-run the whole test on Apple.
            markCloudflareBlocked(retryAfter: retryAfter)
            throw provider == .automatic ? SpeedTestError.rateLimitedDuringTest : SpeedTestError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func markCloudflareBlocked(retryAfter: TimeInterval?) {
        cloudflareBlockedUntil = Date().addingTimeInterval(retryAfter ?? 3600)
    }

    private func runCloudflare(_ id: UUID) async throws -> SpeedTestResult {
        serverLabel = "Cloudflare"
        phase = .latency
        let latency = try await cloudflare.measureLatency()
        try ensureCurrent(id)
        pingMs = latency.pingMs
        jitterMs = latency.jitterMs
        serverLabel = latency.server.map { "Cloudflare · \($0)" } ?? "Cloudflare"

        phase = .download
        let download = try await cloudflare.measure(.download, duration: 10) { [weak self] fraction, mbps in
            guard let self, self.runID == id else { return }
            self.downloadProgress = fraction
            self.downloadMbps = mbps
        }
        try ensureCurrent(id)
        downloadMbps = download
        downloadProgress = 1

        phase = .upload
        let upload = try await cloudflare.measure(.upload, duration: 10) { [weak self] fraction, mbps in
            guard let self, self.runID == id else { return }
            self.uploadProgress = fraction
            self.uploadMbps = mbps
        }
        try ensureCurrent(id)
        uploadMbps = upload
        uploadProgress = 1

        return SpeedTestResult(
            date: Date(),
            downloadMbps: download,
            uploadMbps: upload,
            pingMs: latency.pingMs,
            jitterMs: latency.jitterMs,
            server: latency.server,
            provider: .cloudflare
        )
    }

    /// Apple reports latency together with the download, so there is no separate latency phase.
    private func runApple(_ id: UUID) async throws -> SpeedTestResult {
        serverLabel = "Apple"
        phase = .download
        let download = try await apple.measure(.download) { [weak self] fraction in
            guard let self, self.runID == id else { return }
            self.downloadProgress = fraction
        }
        try ensureCurrent(id)
        downloadMbps = download.mbps
        downloadProgress = 1
        pingMs = download.latency?.pingMs
        jitterMs = download.latency?.jitterMs

        phase = .upload
        let upload = try await apple.measure(.upload) { [weak self] fraction in
            guard let self, self.runID == id else { return }
            self.uploadProgress = fraction
        }
        try ensureCurrent(id)
        uploadMbps = upload.mbps
        uploadProgress = 1

        let latency = download.latency ?? upload.latency
        pingMs = latency?.pingMs
        jitterMs = latency?.jitterMs
        return SpeedTestResult(
            date: Date(),
            downloadMbps: download.mbps,
            uploadMbps: upload.mbps,
            pingMs: latency?.pingMs,
            jitterMs: latency?.jitterMs,
            server: nil,
            provider: .apple
        )
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    // MARK: Network info

    /// The public IP can change between tests (VPN, network switch), so look it up again each time.
    /// A new lookup replaces one still in flight, and only the latest result is applied.
    func refreshNetworkInfo() {
        guard showIPAddress else { return }
        networkInfoTask?.cancel()
        networkInfoGeneration += 1
        let generation = networkInfoGeneration
        networkInfoFailed = false
        networkInfoTask = Task {
            let info = try? await NetworkInfo.fetch()
            guard generation == networkInfoGeneration, showIPAddress, !Task.isCancelled else { return }
            if let info {
                networkInfo = info
            } else {
                // Keep showing the previous IP if there is one.
                networkInfoFailed = networkInfo == nil
            }
        }
    }

    // MARK: Scheduling

    private func scheduleAutoTest() {
        autoTestTask?.cancel()
        nextAutoTest = nil
        guard autoTestMinutes > 0 else { return }

        let interval = TimeInterval(autoTestMinutes * 60)
        nextAutoTest = Date().addingTimeInterval(interval)
        autoTestTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            // The sleep keeps counting while the Mac is asleep, so wait for the network after a wake.
            if let lastWake = self?.lastWake {
                let sinceWake = Date().timeIntervalSince(lastWake)
                if sinceWake < Self.wakeGracePeriod {
                    try? await Task.sleep(for: .seconds(Self.wakeGracePeriod - sinceWake))
                }
            }
            guard !Task.isCancelled, let self else { return }
            if self.provider == .cloudflare && self.isCloudflareBlocked {
                // Testing now would only extend the rate limit.
                self.scheduleAutoTest()
            } else if self.isRunning {
                self.scheduleAutoTest()
            } else {
                // start() schedules the following test.
                self.start()
            }
        }
    }

    /// Clears the block when it expires, so the UI stops saying "Using Apple until …".
    private func scheduleBlockExpiry() {
        blockExpiryTask?.cancel()
        guard let until = cloudflareBlockedUntil else { return }
        blockExpiryTask = Task { [weak self] in
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled, let self, self.cloudflareBlockedUntil == until else { return }
            self.cloudflareBlockedUntil = nil
        }
    }

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastWake = Date() }
        })

        let center = NotificationCenter.default
        // Login item approval and notification permission can change in System Settings.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
                self?.refreshNotificationPermission()
            }
        })
        // Cancelling terminates a running networkQuality process, which would otherwise outlive the app.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    private func refreshNotificationPermission() {
        guard notifyOnFinish else { return }
        Notifier.isAuthorized { [weak self] authorized in
            guard let self, !authorized else { return }
            self.notificationsDenied = true
            self.notifyOnFinish = false
        }
    }
}

enum SpeedFormat {
    static func mbps(_ value: Double) -> String {
        oneDecimalBelowTen(value)
    }

    static func ms(_ value: Double) -> String {
        oneDecimalBelowTen(value)
    }

    /// Rounds first, so 9.96 shows as "10" rather than "10.0".
    private static func oneDecimalBelowTen(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded < 10 ? String(format: "%.1f", rounded) : String(format: "%.0f", value)
    }
}
