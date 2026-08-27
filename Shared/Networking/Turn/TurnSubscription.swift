//
//  TurnSubscription.swift
//  Turn
//

import Foundation

/// Reads a sing-box subscription that carries a `turn` block next to the
/// outbounds, and turns it into proxies with their relay already attached.
///
/// The block is keyed by server hostname, so each VLESS outbound finds the
/// `vk-turn-proxy` front standing in front of that same server:
///
///     "turn": {
///       "version": 1,
///       "vk_link": "https://vk.com/call/join/…",
///       "defaults": { "wrap_mode": true, "num_streams": 10,
///                     "streams_per_cred": 2, "ready_timeout": 30,
///                     "captcha_solver": "v2" },
///       "servers": {
///         "ru.example.com": { "peer_addr": "203.0.113.10:56000",
///                             "wrap_key_hex": "bb0a…", "supported": true }
///       }
///     }
///
/// Outbounds with no matching entry, or one marked `supported: false`, come
/// back as ordinary direct-dial proxies.
nonisolated enum TurnSubscription {

    /// True when the body looks like a sing-box config rather than a list of
    /// share links, so the fetcher knows which parser to reach for.
    static func looksLikeSingBox(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["outbounds"] != nil
    }

    struct Parsed {
        var configurations: [ProxyConfiguration]
        /// Where to ask for this subscriber's own call link, when the
        /// subscription ships a pool service instead of one shared invite.
        var linkEndpoint: String?
        /// A name for the group these belong to, borrowed from the selector that
        /// lists them. Nil when the config has no selector.
        var suggestedName: String?
    }

    static func parse(json body: String) throws -> Parsed {
        guard let data = body.data(using: .utf8),
              let root = try? JSONDecoder().decode(Root.self, from: data)
        else {
            throw TurnError.subscription(.noConfigurations)
        }

        let configurations = root.outbounds.compactMap {
            makeConfiguration($0, turn: root.turn)
        }
        guard !configurations.isEmpty else {
            throw TurnError.subscription(.noConfigurations)
        }
        return Parsed(
            configurations: configurations,
            linkEndpoint: root.turn?.link_endpoint,
            suggestedName: groupName(from: root)
        )
    }

    /// sing-box gathers the proxies under a `selector` outbound whose tag is the
    /// closest thing the config has to a provider name — "→ Remnawave" and the
    /// like. The arrow is decoration, so it goes.
    private static func groupName(from root: Root) -> String? {
        guard let selector = root.outbounds.first(where: { $0.type == "selector" }),
              let tag = selector.tag
        else { return nil }

        let cleaned = tag
            .trimmingCharacters(in: CharacterSet(charactersIn: "→←⇒>- "))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Mapping

    private static func makeConfiguration(_ outbound: Outbound, turn: TurnBlock?) -> ProxyConfiguration? {
        guard outbound.type == "vless",
              let server = outbound.server,
              let port = outbound.server_port,
              let uuidString = outbound.uuid,
              let uuid = UUID(uuidString: uuidString)
        else { return nil }

        return ProxyConfiguration(
            name: outbound.tag ?? server,
            serverAddress: server,
            serverPort: port,
            outbound: .vless(
                uuid: uuid,
                encryption: "none",
                flow: outbound.flow,
                transport: .raw,
                security: makeSecurityLayer(outbound.tls, serverAddress: server)
            ),
            turn: turn?.configuration(forServer: server)
        )
    }

    private static func makeSecurityLayer(_ tls: TLS?, serverAddress: String) -> XraySecurityLayer {
        guard let tls, tls.enabled == true else { return .none }
        let serverName = tls.server_name ?? serverAddress
        let fingerprint = TLSFingerprint(fromSingBox: tls.utls?.fingerprint)

        if let reality = tls.reality, reality.enabled == true,
           let key = reality.public_key,
           let publicKey = Data(base64URLEncoded: key), publicKey.count == 32 {
            return .reality(RealityConfiguration(
                serverName: serverName,
                publicKey: publicKey,
                shortId: Data(hexString: reality.short_id ?? "") ?? Data(),
                fingerprint: fingerprint
            ))
        }

        return .tls(TLSConfiguration(
            serverName: serverName,
            alpn: tls.alpn,
            fingerprint: fingerprint,
            insecureSkipVerify: tls.insecure ?? false
        ))
    }

    // MARK: - Wire format

    private struct Root: Decodable {
        var outbounds: [Outbound]
        var turn: TurnBlock?
    }

    private struct Outbound: Decodable {
        var type: String
        var tag: String?
        var server: String?
        var server_port: UInt16?
        var uuid: String?
        var flow: String?
        var tls: TLS?
    }

    private struct TLS: Decodable {
        var enabled: Bool?
        var server_name: String?
        var insecure: Bool?
        var alpn: [String]?
        var reality: Reality?
        var utls: UTLS?
    }

    private struct Reality: Decodable {
        var enabled: Bool?
        var public_key: String?
        var short_id: String?
    }

    private struct UTLS: Decodable {
        var enabled: Bool?
        var fingerprint: String?
    }

    private struct TurnBlock: Decodable {
        var version: Int?
        var vk_link: String?
        var vk_link_required: Bool?
        var link_endpoint: String?
        var defaults: Defaults?
        var servers: [String: Server]?

        struct Defaults: Decodable {
            var wrap_mode: Bool?
            var vless_bond: Bool?
            var num_streams: Int?
            var streams_per_cred: Int?
            var ready_timeout: Int?
            var captcha_solver: String?
        }

        struct Server: Decodable {
            var peer_addr: String?
            var wrap_key_hex: String?
            var supported: Bool?
        }

        /// The relay standing in front of `server`, or nil when the
        /// subscription has none for it.
        func configuration(forServer server: String) -> TurnConfiguration? {
            // The call link is deliberately not required here. A subscription may
            // ship the relay without one and leave the user to supply their own
            // in Settings; demanding it at parse time would drop the relay
            // entirely and the setting would silently never apply.
            guard let entry = servers?[server],
                  entry.supported != false,
                  let peer = entry.peer_addr, !peer.isEmpty
            else { return nil }

            let wrapWanted = defaults?.wrap_mode ?? true
            return TurnConfiguration(
                peerAddress: peer,
                link: vk_link ?? "",
                wrapKeyHex: wrapWanted ? (entry.wrap_key_hex ?? "") : "",
                // The fronts run with `-vless-bond`; the block carries no flag
                // for it yet, so assume on unless it says otherwise.
                bond: defaults?.vless_bond ?? true,
                streams: defaults?.num_streams ?? 0,
                streamsPerCred: defaults?.streams_per_cred ?? 0,
                readyTimeout: defaults?.ready_timeout ?? 0,
                captchaSolver: defaults?.captcha_solver ?? "v2"
            )
        }
    }
}

// MARK: - Fingerprint names

nonisolated extension TLSFingerprint {
    /// sing-box names a browser family (`firefox`), this enum names a version
    /// (`firefox_148`). An unversioned name maps to the newest of that family;
    /// anything unrecognised falls back to Chrome 120, matching the share-link
    /// parser.
    init(fromSingBox name: String?) {
        guard let name = name?.lowercased(), !name.isEmpty else {
            self = .chrome120
            return
        }
        if let exact = TLSFingerprint(rawValue: name) {
            self = exact
            return
        }
        switch name {
        case "chrome":  self = .chrome133
        case "firefox": self = .firefox148
        case "safari":  self = .safari26
        case "edge":    self = .edge106
        default:        self = .chrome120
        }
    }
}
