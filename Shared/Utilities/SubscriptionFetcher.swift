//
//  SubscriptionFetcher.swift
//  Turn
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated private let logger = TurnLogger(category: "SubscriptionFetcher")

nonisolated struct SubscriptionFetcher {
    struct Result {
        let configurations: [ProxyConfiguration]
        let name: String?
        let upload: Int64?
        let download: Int64?
        let total: Int64?
        let expire: Date?
    }

    static func fetch(url urlString: String, withRemnawaveHWID: Bool = false) async throws -> Result {
        guard let url = URL(string: urlString) else {
            throw TurnError.subscription(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if withRemnawaveHWID {
            request.setValue(AWCore.getRemnawaveHWID(), forHTTPHeaderField: "x-hwid")
        }

        let allowInsecure = AWCore.getAllowInsecure()
        let (data, response): (Data, URLResponse)
        do {
            if let viaUpstream = try await fetchViaConfiguredDNS(request, allowInsecure: allowInsecure) {
                (data, response) = viaUpstream
            } else if allowInsecure {
                let session = URLSession(configuration: .default, delegate: InsecureSessionDelegate(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                (data, response) = try await session.data(for: request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw TurnError.subscription(.fetchFailed(underlying: error))
        }

        let httpResponse = response as? HTTPURLResponse

        let profileTitle = parseProfileTitle(from: httpResponse)
        let userInfo = parseSubscriptionUserInfo(from: httpResponse)

        let bodyString: String
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           let decodedString = String(data: decoded, encoding: .utf8),
           ProxyConfiguration.parsableURLPrefixes.contains(where: { decodedString.contains($0) }) {
            bodyString = decodedString
        } else if let rawString = String(data: data, encoding: .utf8) {
            bodyString = rawString
        } else {
            throw TurnError.subscription(.noConfigurations)
        }

        // A sing-box body carries the `turn` block that pairs each outbound with
        // its relay, so it has to be parsed before the share-link path.
        if TurnSubscription.looksLikeSingBox(bodyString) {
            let parsed = try TurnSubscription.parse(json: bodyString)
            let relayed = parsed.configurations.filter { $0.turn != nil }.count
            logger.info("Parsed \(parsed.configurations.count) sing-box outbound(s), \(relayed) with a VK TURN relay")
            let configurations = await pinCallLink(
                in: parsed.configurations,
                endpoint: parsed.linkEndpoint,
                subscriptionURL: url
            )
            return Result(
                configurations: configurations,
                name: profileTitle ?? parsed.suggestedName,
                upload: userInfo.upload,
                download: userInfo.download,
                total: userInfo.total,
                expire: userInfo.expire
            )
        }

        if bodyString.contains("proxies:") {
            let result = try ClashProxyParser.parse(yaml: bodyString)
            guard !result.configurations.isEmpty else {
                throw TurnError.subscription(.noConfigurations)
            }
            return Result(
                configurations: result.configurations,
                name: profileTitle,
                upload: userInfo.upload,
                download: userInfo.download,
                total: userInfo.total,
                expire: userInfo.expire
            )
        }

        let configurations = bodyString
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ProxyConfiguration.canParseURL($0) }
            .compactMap { try? ProxyConfiguration.parse(url: $0) }

        guard !configurations.isEmpty else {
            throw TurnError.subscription(.noConfigurations)
        }

        return Result(
            configurations: configurations,
            name: profileTitle,
            upload: userInfo.upload,
            download: userInfo.download,
            total: userInfo.total,
            expire: userInfo.expire
        )
    }

    // MARK: - Per-subscriber call link

    private struct PinnedLink: Decodable {
        let vk_link: String
    }

    /// Replaces the subscription's shared `vk_link` with the one pinned to this
    /// subscriber, when the subscription points at a pool service.
    ///
    /// One invite shared by everybody does not hold up: each relay stream joins
    /// the VK call as its own participant, so a few users on one call means
    /// constant captchas. Asking here — rather than in the tunnel — keeps the
    /// network extension free of an extra request it would have to make while
    /// bringing the tunnel up.
    ///
    /// Any failure leaves the configurations untouched, so the shared link from
    /// the subscription still works.
    private static func pinCallLink(
        in configurations: [ProxyConfiguration],
        endpoint: String?,
        subscriptionURL: URL
    ) async -> [ProxyConfiguration] {
        guard let endpoint, !endpoint.isEmpty,
              configurations.contains(where: { $0.turn != nil })
        else { return configurations }

        let subscriber = subscriptionURL.lastPathComponent
        guard !subscriber.isEmpty,
              var components = URLComponents(string: endpoint)
        else { return configurations }
        components.queryItems = [URLQueryItem(name: "sub", value: subscriber)]
        guard let requestURL = components.url else { return configurations }

        var request = URLRequest(url: requestURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Short on purpose: this is one HTTP call to the panel that answers in
        // milliseconds when it is well, and the import waits on it before the
        // servers appear. Fifteen seconds only bought a longer stare at a
        // spinner when the endpoint was unreachable — and the fallback, the
        // subscription's own shared link, is perfectly usable.
        request.timeoutInterval = 5

        let started = ContinuousClock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            logger.info("Call-link endpoint answered in \(Self.elapsedMilliseconds(since: started)) ms")
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // 409 means the pool ran dry; the user can still paste their own
                // link in Settings, so this is worth saying out loud but is not
                // a failure of the subscription.
                logger.warning("Call-link endpoint answered \(status); keeping the subscription's shared link")
                return configurations
            }
            let pinned = try JSONDecoder().decode(PinnedLink.self, from: data)
            guard !pinned.vk_link.isEmpty else { return configurations }

            logger.info("Pinned a VK call link for this subscription")
            return configurations.map { $0.withTurnLink(pinned.vk_link) }
        } catch {
            logger.warning("Call-link endpoint unreachable after \(Self.elapsedMilliseconds(since: started)) ms "
                           + "(\(error.localizedDescription)); keeping the subscription's shared link")
            return configurations
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// How the app identifies itself when fetching a subscription.
    ///
    /// The panel keys its response rules off this: a rule matching "Turn" hands
    /// back the sing-box template carrying the VK TURN block, while every other
    /// client keeps getting the ordinary config it understands.
    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Turn/\(version ?? "1.0")"
    }()

    // MARK: - Configured DNS
    
    private static func fetchViaConfiguredDNS(_ request: URLRequest, allowInsecure: Bool) async throws -> (Data, URLResponse)? {
        let upstream = AWCore.getSubscriptionDNSUpstream()
        guard !upstream.isSystem else { return nil }

        let result = try await ResolvedHostFetcher.fetch(request, allowInsecure: allowInsecure) { host in
            try await DNSUpstreamClient.resolve(host, via: upstream).first
        }
        return (result.data, result.response)
    }

    // MARK: - Header Parsing

    private static func parseProfileTitle(from response: HTTPURLResponse?) -> String? {
        guard let value = response?.value(forHTTPHeaderField: "profile-title") else { return nil }
        let decoded: String
        if value.hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            if let data = Data(base64Encoded: encoded),
               let utf8 = String(data: data, encoding: .utf8) {
                decoded = utf8
            } else {
                decoded = value
            }
        } else {
            decoded = value
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : decoded
    }

    private static func parseSubscriptionUserInfo(from response: HTTPURLResponse?) -> (upload: Int64?, download: Int64?, total: Int64?, expire: Date?) {
        guard let value = response?.value(forHTTPHeaderField: "subscription-userinfo") else {
            return (nil, nil, nil, nil)
        }

        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: Date?

        // Format: upload=X; download=Y; total=Z; expire=T
        for part in value.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let keyValue = trimmed.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let valueString = keyValue[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "upload":
                upload = Int64(valueString)
            case "download":
                download = Int64(valueString)
            case "total":
                total = Int64(valueString)
            case "expire":
                if let timestamp = TimeInterval(valueString) {
                    expire = Date(timeIntervalSince1970: timestamp)
                }
            default:
                break
            }
        }

        return (upload, download, total, expire)
    }
}

// MARK: - URLSession delegate that accepts self-signed certificates

nonisolated private final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
