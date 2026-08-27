//
//  TurnLinkTests.swift
//  Turn
//

import Testing
import Foundation
@testable import Turn

/// TURN has no UI of its own — the subscription is the whole configuration
/// surface, so the parsing is what has to be right.
@Suite
struct TurnSubscriptionTests {

    /// Shaped like the real subscription: a sing-box config with a `turn` block
    /// keyed by server hostname. One server is relayed, one is explicitly not.
    private static let body = """
    {
      "outbounds": [
        {"tag": "→ Remnawave", "type": "selector", "outbounds": ["RU", "JP"]},
        {"tag": "direct", "type": "direct"},
        {"type": "vless", "tag": "RU", "server": "ru.example.com", "server_port": 443,
         "uuid": "5d212819-2cdc-47e7-bf8c-f061e1886011", "flow": "xtls-rprx-vision",
         "tls": {"enabled": true, "server_name": "ya.ru",
                 "reality": {"enabled": true, "public_key": "KCMZxzdZ3Fdm8AVh4YZ_gk2n9zUQRoZJMyfBst0Cfl4"},
                 "utls": {"enabled": true, "fingerprint": "firefox"}}},
        {"type": "vless", "tag": "JP", "server": "jp.example.com", "server_port": 443,
         "uuid": "5d212819-2cdc-47e7-bf8c-f061e1886011", "flow": "xtls-rprx-vision",
         "tls": {"enabled": true, "server_name": "ya.ru",
                 "reality": {"enabled": true, "public_key": "KCMZxzdZ3Fdm8AVh4YZ_gk2n9zUQRoZJMyfBst0Cfl4"},
                 "utls": {"enabled": true, "fingerprint": "firefox"}}}
      ],
      "turn": {
        "version": 1,
        "vk_link_required": true,
        "vk_link": "https://vk.com/call/join/AbCdEf-123_xyz",
        "defaults": {"wrap_mode": true, "num_streams": 10, "ready_timeout": 30,
                     "captcha_solver": "v2", "streams_per_cred": 2},
        "servers": {
          "ru.example.com": {"peer_addr": "203.0.113.10:56000", "supported": true,
                             "wrap_key_hex": "bb0acb4817a39794a8afc02c7fb487f1"},
          "jp.example.com": {"peer_addr": "203.0.113.20:56000", "supported": false,
                             "wrap_key_hex": "5c436e64781936bc75422bf0446032e8"}
        }
      }
    }
    """

    @Test("A sing-box body is recognised, a share-link list is not")
    func detection() {
        #expect(TurnSubscription.looksLikeSingBox(Self.body))
        #expect(!TurnSubscription.looksLikeSingBox("vless://uuid@host:443#Name"))
        #expect(!TurnSubscription.looksLikeSingBox("not json at all"))
    }

    @Test("Only VLESS outbounds become proxies")
    func skipsNonProxyOutbounds() throws {
        let configs = try TurnSubscription.parse(json: Self.body)
        #expect(configs.count == 2)
        #expect(configs.map(\.name) == ["RU", "JP"])
    }

    @Test("A relayed server gets its front attached")
    func attachesRelay() throws {
        let config = try #require(try TurnSubscription.parse(json: Self.body).first { $0.name == "RU" })
        let turn = try #require(config.turn)

        #expect(turn.peerAddress == "203.0.113.10:56000")
        #expect(turn.link == "https://vk.com/call/join/AbCdEf-123_xyz")
        #expect(turn.wrapKeyHex == "bb0acb4817a39794a8afc02c7fb487f1")
        #expect(turn.streams == 10)
        #expect(turn.streamsPerCred == 2)
        #expect(turn.resolvedReadyTimeout == 30)
        #expect(turn.captchaSolver == "v2")

        // The real endpoint is untouched — the relay is a detour, not a replacement.
        #expect(config.serverAddress == "ru.example.com")
        #expect(config.serverPort == 443)
    }

    @Test("supported:false means dial directly")
    func honoursUnsupported() throws {
        let config = try #require(try TurnSubscription.parse(json: Self.body).first { $0.name == "JP" })
        #expect(config.turn == nil)
    }

    @Test("Reality survives the mapping, including the browser fingerprint")
    func mapsReality() throws {
        let config = try #require(try TurnSubscription.parse(json: Self.body).first)
        guard case .vless(_, _, let flow, let transport, let security) = config.outbound else {
            Issue.record("expected a VLESS outbound"); return
        }
        #expect(flow == "xtls-rprx-vision")
        #expect(transport == .raw)
        guard case .reality(let reality) = security else {
            Issue.record("expected Reality"); return
        }
        #expect(reality.serverName == "ya.ru")
        #expect(reality.publicKey.count == 32)
        // sing-box says "firefox"; this enum names versions.
        #expect(reality.fingerprint == .firefox148)
    }

    @Test("Redirecting to the relay leaves the Reality handshake alone")
    func redirectKeepsHandshake() throws {
        let config = try #require(try TurnSubscription.parse(json: Self.body).first { $0.name == "RU" })
        let turn = try #require(config.turn)
        let redirected = config.withRedirectedServer(address: "127.0.0.1", port: turn.resolvedListenPort)

        #expect(redirected.serverAddress == "127.0.0.1")
        #expect(redirected.serverPort == 9000)
        #expect(redirected.outbound == config.outbound)
        #expect(redirected.turn == config.turn)
    }

    @Test("The core is started in VLESS mode on the relay's local port")
    func coreConfigJSON() throws {
        let config = try #require(try TurnSubscription.parse(json: Self.body).first { $0.name == "RU" })
        let turn = try #require(config.turn)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(turn.makeCoreConfigJSON().utf8)) as? [String: Any]
        )

        #expect(decoded["listen"] as? String == "127.0.0.1:9000")
        #expect(decoded["peer_addr"] as? String == "203.0.113.10:56000")
        #expect(decoded["vk_link"] as? String == "https://vk.com/call/join/AbCdEf-123_xyz")
        #expect(decoded["vless_mode"] as? Bool == true)
        #expect(decoded["vless_bond"] as? Bool == true)
        #expect(decoded["wrap_mode"] as? Bool == true)
        #expect(decoded["num_streams"] as? Int == 10)
        #expect(decoded["streams_per_cred"] as? Int == 2)
    }
}
