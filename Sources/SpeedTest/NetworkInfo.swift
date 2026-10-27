import Foundation

/// Public IP address and network owner.
struct NetworkInfo: Equatable, Sendable {
    let ip: String
    let provider: String?
    let city: String?
    /// ISO region code, e.g. "HU".
    let countryCode: String?

    var location: String? {
        let country = countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        let parts = [city, country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    init?(ip: String?, provider: String?, city: String?, countryCode: String?) {
        guard let ip = ip?.nonEmpty else { return nil }
        self.ip = ip
        self.provider = provider?.nonEmpty
        self.city = city?.nonEmpty
        self.countryCode = countryCode?.nonEmpty?.uppercased()
    }

    /// Free lookup services rate-limit per IP, and VPN exit IPs are shared by many users,
    /// so ask them all at once and use the most preferred one that answers. IPv4 sources
    /// come first so the address shown doesn't flip between IPv4 and IPv6.
    static func fetch() async throws -> NetworkInfo {
        let sources: [@Sendable (URLSession) async throws -> NetworkInfo] = [
            { try await ipSB($0) }, { try await ipInfo($0) }, { try await ipWhoIs($0) }, { try await cloudflareTrace($0) },
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        return try await withThrowingTaskGroup(of: (Int, NetworkInfo?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { (index, try? await source(session)) }
            }
            var results: [Int: NetworkInfo?] = [:]
            for try await (index, info) in group {
                results[index] = info
                // Done once every more-preferred source has answered or failed.
                for preferred in sources.indices {
                    guard let answer = results[preferred] else { break }
                    if let answer {
                        group.cancelAll()
                        return answer
                    }
                }
            }
            throw URLError(.cannotLoadFromNetwork)
        }
    }

    // MARK: Sources

    private static func ipSB(_ session: URLSession) async throws -> NetworkInfo {
        struct Response: Decodable {
            let ip: String?
            let isp: String?
            let city: String?
            let country_code: String?
        }
        let r: Response = try await getJSON("https://api-ipv4.ip.sb/geoip", session)
        return try NetworkInfo(ip: r.ip, provider: r.isp, city: r.city, countryCode: r.country_code).orThrow()
    }

    private static func ipInfo(_ session: URLSession) async throws -> NetworkInfo {
        struct Response: Decodable {
            let ip: String?
            let org: String?
            let city: String?
            let country: String?
        }
        let r: Response = try await getJSON("https://ipinfo.io/json", session)
        // `org` looks like "AS64500 Example ISP"; drop the AS number.
        let provider = r.org.map { org in
            let parts = org.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].hasPrefix("AS") ? String(parts[1]) : org
        }
        return try NetworkInfo(ip: r.ip, provider: provider, city: r.city, countryCode: r.country).orThrow()
    }

    /// May answer with IPv6 on dual-stack networks, so it ranks below the IPv4 sources.
    private static func ipWhoIs(_ session: URLSession) async throws -> NetworkInfo {
        struct Response: Decodable {
            struct Connection: Decodable { let isp: String? }
            let success: Bool
            let ip: String?
            let city: String?
            let country_code: String?
            let connection: Connection?
        }
        // Errors come back as 200 with `"success": false`.
        let r: Response = try await getJSON("https://ipwho.is/", session)
        guard r.success else { throw URLError(.badServerResponse) }
        return try NetworkInfo(ip: r.ip, provider: r.connection?.isp, city: r.city, countryCode: r.country_code).orThrow()
    }

    /// Plain `key=value` lines, e.g. `ip=203.0.113.7` and `loc=US`. The IP literal host forces IPv4.
    private static func cloudflareTrace(_ session: URLSession) async throws -> NetworkInfo {
        let data = try await get("https://1.1.1.1/cdn-cgi/trace", session)
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return try NetworkInfo(ip: fields["ip"], provider: nil, city: nil, countryCode: fields["loc"]).orThrow()
    }

    // MARK: HTTP

    private static func getJSON<T: Decodable>(_ url: String, _ session: URLSession) async throws -> T {
        try JSONDecoder().decode(T.self, from: await get(url, session))
    }

    private static func get(_ url: String, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private extension Optional where Wrapped == NetworkInfo {
    func orThrow() throws -> NetworkInfo {
        guard let self else { throw URLError(.cannotParseResponse) }
        return self
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
