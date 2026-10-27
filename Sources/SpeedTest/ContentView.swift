import Charts
import SwiftUI

struct ContentView: View {
    enum Tab: Hashable { case test, history, settings }

    @EnvironmentObject private var state: AppState
    @State private var tab: Tab

    init(tab: Tab = .test) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        // A fixed size keeps MenuBarExtra from resizing (and clipping) the window between tabs.
        VStack(spacing: 12) {
            HStack {
                Label("Speed Test", systemImage: "speedometer")
                    .font(.headline)
                Spacer()
                if let server = state.serverLabel ?? state.lastResult?.serverLabel {
                    Text(server)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Picker("", selection: $tab) {
                Text("Test").tag(Tab.test)
                Text("History").tag(Tab.history)
                Text("Settings").tag(Tab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .test: TestView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Text(poweredBy)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340, height: 436)
    }

    private var poweredBy: String {
        let label = state.serverLabel ?? state.lastResult?.serverLabel ?? "Cloudflare"
        return label.hasPrefix("Apple") ? "Powered by Apple networkQuality" : "Powered by speed.cloudflare.com"
    }
}

// MARK: - Test

private struct TestView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Button {
                state.isRunning ? state.cancel() : state.start()
            } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(state.isRunning ? .gray : .accentColor)

            SpeedBar(
                title: "Download",
                systemImage: "arrow.down.circle.fill",
                mbps: state.downloadMbps ?? (showsLastResult ? state.lastResult?.downloadMbps : nil),
                progress: showsLastResult ? 1 : state.downloadProgress,
                isActive: state.phase == .download,
                colors: [.cyan, .blue]
            )

            SpeedBar(
                title: "Upload",
                systemImage: "arrow.up.circle.fill",
                mbps: state.uploadMbps ?? (showsLastResult ? state.lastResult?.uploadMbps : nil),
                progress: showsLastResult ? 1 : state.uploadProgress,
                isActive: state.phase == .upload,
                colors: [.purple, .pink]
            )

            HStack(spacing: 10) {
                StatTile(title: "Ping", value: pingValue.map(SpeedFormat.ms), unit: "ms", isActive: state.isRunning)
                StatTile(title: "Jitter", value: jitterValue.map(SpeedFormat.ms), unit: "ms", isActive: state.isRunning)
            }

            if state.showIPAddress {
                IPAddressRow(info: state.networkInfo, isFailed: state.networkInfoFailed, retry: state.refreshNetworkInfo)
            }

            statusLine
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
    }

    private var buttonTitle: String {
        switch state.phase {
        case .latency, .download, .upload: "Cancel"
        case .finished, .failed: "Test Again"
        case .idle, .cancelled: state.lastResult == nil ? "Start Test" : "Test Again"
        }
    }

    /// After launch the bars show the previous result instead of sitting empty.
    private var showsLastResult: Bool {
        [.idle, .cancelled].contains(state.phase) && state.lastResult != nil
    }

    private var pingValue: Double? {
        state.pingMs ?? (showsLastResult ? state.lastResult?.pingMs ?? nil : nil)
    }

    private var jitterValue: Double? {
        state.jitterMs ?? (showsLastResult ? state.lastResult?.jitterMs ?? nil : nil)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.phase {
        case .latency:
            Text("Measuring latency…").foregroundStyle(.secondary)
        case .download:
            Text("Testing download speed…").foregroundStyle(.secondary)
        case .upload:
            Text("Testing upload speed…").foregroundStyle(.secondary)
        case .finished:
            Text("Test complete").foregroundStyle(.green)
        case .cancelled:
            Text("Test cancelled").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
        case .idle:
            if let last = state.lastResult {
                Text("Last test \(last.date, style: .relative) ago").foregroundStyle(.secondary)
            } else {
                Text("Press Start Test to measure your connection").foregroundStyle(.secondary)
            }
        }
    }
}

private struct SpeedBar: View {
    let title: String
    let systemImage: String
    let mbps: Double?
    let progress: Double
    let isActive: Bool
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer()
                Text(mbps.map(SpeedFormat.mbps) ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: mbps)
                Text("Mbps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: progress > 0 ? max(geo.size.width * progress, 8) : 0)
                        .animation(.linear(duration: 0.15), value: progress)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Shimmer().frame(width: progress > 0 ? max(geo.size.width * progress, 8) : 0)
                            }
                        }
                        .clipShape(Capsule())
                }
            }
            .frame(height: 8)
        }
    }
}

/// A highlight that sweeps across the active bar. Driven by the clock rather than a state
/// animation, so the bar's frequent width changes don't restart or distort it.
private struct Shimmer: View {
    private static let period = 1.1
    private static let highlightWidth: CGFloat = 60

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.highlightWidth)
                    .offset(x: phase * (geo.size.width + Self.highlightWidth) - Self.highlightWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StatTile: View {
    let title: String
    let value: String?
    let unit: String
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if isActive && value == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(value ?? "—")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct IPAddressRow: View {
    let info: NetworkInfo?
    let isFailed: Bool
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            if let info {
                Text(info.ip)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let detail = [info.provider, info.location].compactMap({ $0 }).first {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help([info.provider, info.location].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.ip, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help("Copy IP address")
                .accessibilityLabel(copied ? "Copied" : "Copy IP address")
                // Restarts on every copy and is cancelled with the view.
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } else if isFailed {
                Text("IP address unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help("Try again")
                .accessibilityLabel("Retry IP address lookup")
            } else {
                Text("Looking up IP address…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - History

private struct HistoryView: View {
    @EnvironmentObject private var state: AppState

    private static let visibleRows: CGFloat = 4

    @State private var confirmingClear = false

    private var recent: [SpeedTestResult] {
        Array(state.history.prefix(20).reversed())
    }

    /// A line needs two points at different times; otherwise the chart is empty or a vertical line.
    private var canChart: Bool {
        guard let first = recent.first?.date, let last = recent.last?.date else { return false }
        return last.timeIntervalSince(first) >= 60
    }

    var body: some View {
        if state.history.isEmpty {
            ContentUnavailableView(
                "No tests yet",
                systemImage: "chart.xyaxis.line",
                description: Text("Run a test to start building history.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                if canChart {
                    chart
                } else {
                    Text("The chart appears after a few more tests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Exactly `visibleRows` tall so no row is ever cut off; the rest scrolls.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.history) { result in
                            HistoryRow(result: result)
                            if result.id != state.history.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.visible)
                .frame(height: HistoryRow.height * Self.visibleRows + (Self.visibleRows - 1))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("\(state.history.count) of \(AppState.historyLimit) tests")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .confirmationDialog("Clear all \(state.history.count) saved tests?", isPresented: $confirmingClear) {
                            Button("Clear History", role: .destructive) { state.clearHistory() }
                        }
                }
            }
        }
    }

    private var chart: some View {
        Chart(recent) { result in
            LineMark(x: .value("Date", result.date), y: .value("Mbps", result.downloadMbps), series: .value("Type", "Download"))
                .foregroundStyle(by: .value("Type", "Download"))
            PointMark(x: .value("Date", result.date), y: .value("Mbps", result.downloadMbps))
                .foregroundStyle(by: .value("Type", "Download"))
                .symbolSize(18)
            LineMark(x: .value("Date", result.date), y: .value("Mbps", result.uploadMbps), series: .value("Type", "Upload"))
                .foregroundStyle(by: .value("Type", "Upload"))
            PointMark(x: .value("Date", result.date), y: .value("Mbps", result.uploadMbps))
                .foregroundStyle(by: .value("Type", "Upload"))
                .symbolSize(18)
        }
        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.purple])
        .chartLegend(position: .top, alignment: .leading)
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    static let height: CGFloat = 26

    let result: SpeedTestResult

    var body: some View {
        HStack {
            Text(result.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("↓ \(SpeedFormat.mbps(result.downloadMbps))")
                .foregroundStyle(.blue)
                .frame(width: 56, alignment: .trailing)
            Text("↑ \(SpeedFormat.mbps(result.uploadMbps))")
                .foregroundStyle(.purple)
                .frame(width: 52, alignment: .trailing)
            Text(result.pingMs.map { "\(SpeedFormat.ms($0)) ms" } ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .frame(height: Self.height)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "General") {
                SettingsRow(
                    systemImage: "power",
                    title: "Launch at login",
                    subtitle: launchSubtitle
                ) {
                    Toggle("Launch at login", isOn: $state.launchAtLogin)
                }
                Divider().padding(.leading, 36)
                SettingsRow(
                    systemImage: "bell.badge",
                    title: "Notifications",
                    subtitle: state.notificationsDenied
                        ? "Turned off in System Settings › Notifications"
                        : "Show results when a test ends"
                ) {
                    Toggle("Notifications", isOn: $state.notifyOnFinish)
                }
                Divider().padding(.leading, 36)
                SettingsRow(
                    systemImage: "network",
                    title: "Show IP address",
                    subtitle: "Public IP and network provider"
                ) {
                    Toggle("Show IP address", isOn: $state.showIPAddress)
                }
            }

            SettingsSection(title: "Testing") {
                SettingsRow(
                    systemImage: "server.rack",
                    title: "Server",
                    subtitle: serverSubtitle
                ) {
                    Picker("Server", selection: $state.provider) {
                        ForEach(Provider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .fixedSize()
                }
                Divider().padding(.leading, 36)
                SettingsRow(
                    systemImage: "clock.arrow.circlepath",
                    title: "Run a test",
                    subtitle: autoTestSubtitle
                ) {
                    Picker("Run a test", selection: $state.autoTestMinutes) {
                        Text("Off").tag(0)
                        Text("Every 15 min").tag(15)
                        Text("Every 30 min").tag(30)
                        Text("Every hour").tag(60)
                        Text("Every 3 hours").tag(180)
                    }
                    .fixedSize()
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
    }

    private var launchSubtitle: String {
        if let error = state.launchAtLoginError { return error }
        if state.launchAtLoginNeedsApproval { return "Approve in System Settings › Login Items" }
        if !state.isInstalledInApplications { return "Install with ./build.sh --install first" }
        return "Start Speed Test when you log in"
    }

    private var serverSubtitle: Text {
        switch state.provider {
        case .automatic:
            if state.isCloudflareBlocked, let until = state.cloudflareBlockedUntil {
                return Text("Using Apple until \(until, style: .time)")
            }
            return Text("Cloudflare, then Apple")
        case .cloudflare:
            return Text("Live progress, may rate-limit")
        case .apple:
            return Text("Built-in networkQuality")
        }
    }

    private var autoTestSubtitle: Text {
        if let next = state.nextAutoTest {
            Text("Next test at \(next, style: .time)")
        } else {
            Text("Off")
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let systemImage: String
    let title: String
    let subtitle: Text
    @ViewBuilder let control: Control

    init(systemImage: String, title: String, subtitle: String, @ViewBuilder control: () -> Control) {
        self.init(systemImage: systemImage, title: title, subtitle: Text(subtitle), control: control)
    }

    init(systemImage: String, title: String, subtitle: Text, @ViewBuilder control: () -> Control) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
