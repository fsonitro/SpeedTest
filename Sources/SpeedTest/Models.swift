import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable {
    /// Cloudflare, falling back to Apple while Cloudflare rate-limits us.
    case automatic
    case cloudflare
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .cloudflare: "Cloudflare"
        case .apple: "Apple"
        }
    }
}

struct SpeedTestResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var downloadMbps: Double
    var uploadMbps: Double
    /// Nil when the provider reported no latency.
    var pingMs: Double?
    var jitterMs: Double?
    var server: String?
    /// Missing in results saved before Apple was added; those came from Cloudflare.
    var provider: Provider?

    var serverLabel: String {
        switch provider ?? .cloudflare {
        case .apple: "Apple"
        case .automatic, .cloudflare: server.map { "Cloudflare · \($0)" } ?? "Cloudflare"
        }
    }
}

extension [SpeedTestResult] {
    /// Decodes entry by entry, so one unreadable entry (e.g. written by another version) doesn't lose the rest.
    static func decodeLossy(from data: Data) -> [SpeedTestResult] {
        ((try? JSONDecoder().decode([LossyResult].self, from: data)) ?? []).compactMap(\.value)
    }
}

private struct LossyResult: Decodable {
    let value: SpeedTestResult?

    init(from decoder: Decoder) throws {
        value = try? SpeedTestResult(from: decoder)
    }
}

struct LatencyResult {
    var pingMs: Double
    var jitterMs: Double
    var server: String?

    /// Median as ping, mean difference between consecutive samples as jitter.
    init?(samples: [Double], server: String? = nil) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let diffs = zip(samples, samples.dropFirst()).map { abs($0 - $1) }
        pingMs = sorted[sorted.count / 2]
        jitterMs = diffs.isEmpty ? 0 : diffs.reduce(0, +) / Double(diffs.count)
        self.server = server
    }
}

enum TransferKind {
    case download, upload
}
