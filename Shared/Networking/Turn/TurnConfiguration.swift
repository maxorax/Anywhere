//
//  TurnConfiguration.swift
//  Turn
//

import Foundation

/// Relaying an outbound through VK Calls TURN servers instead of dialling the
/// proxy host directly.
///
/// The proxy core raises a local TCP listener and tunnels everything written to
/// it through a VK Calls relay to a `vk-turn-proxy` server sitting in front of
/// the real inbound. From the outbound's point of view only the dial address
/// changes: the VLESS/Reality handshake still runs end-to-end against the real
/// server, so the SNI, public key and flow are untouched.
///
/// This is not configured by hand. The subscription carries a `turn` block
/// alongside the outbounds, keyed by server hostname — see
/// ``TurnSubscription``.
nonisolated struct TurnConfiguration: Hashable, Codable, Sendable {

    /// `host:port` of the `vk-turn-proxy` server, UDP.
    var peerAddress: String
    /// The VK Calls invite link the relay credentials are scraped from.
    var link: String
    /// Local TCP port the core listens on; the outbound dials this instead of
    /// the real server. 0 means "use the default".
    var listenPort: UInt16
    /// ChaCha20-Poly1305 obfuscation key, hex. Must match the server's
    /// `-wrap-key`; empty disables it.
    var wrapKeyHex: String
    /// Spread one TCP connection across several relay streams. Requires
    /// `-vless-bond` on the server.
    var bond: Bool
    /// Parallel relay streams. 0 means "core default".
    var streams: Int
    /// Streams served per set of VK credentials. 0 means "core default".
    var streamsPerCred: Int
    /// Seconds to wait for the listener before giving up.
    var readyTimeout: Int
    /// Which automatic captcha solver the core should try first: `v1` or `v2`.
    var captchaSolver: String
    /// Skip the automatic solvers and go straight to the page the user solves by
    /// hand. The subscription has no say in this — it is the user's call.
    var manualCaptcha: Bool

    /// How many streams the core gets from one set of VK credentials.
    ///
    /// Matches `streamsPerCache` in the Go core. Streams beyond this need another
    /// set, which is another request to VK and another chance of a captcha.
    static let streamsPerCredentialSet = 10

    static let defaultListenPort: UInt16 = 9000
    static let defaultReadyTimeout = 45

    var resolvedListenPort: UInt16 { listenPort == 0 ? Self.defaultListenPort : listenPort }
    var listenAddress: String { "127.0.0.1:\(resolvedListenPort)" }
    var resolvedReadyTimeout: Int { readyTimeout > 0 ? readyTimeout : Self.defaultReadyTimeout }

    init(
        peerAddress: String,
        link: String,
        listenPort: UInt16 = 0,
        wrapKeyHex: String = "",
        bond: Bool = true,
        streams: Int = 0,
        streamsPerCred: Int = 0,
        readyTimeout: Int = 0,
        captchaSolver: String = "v2",
        manualCaptcha: Bool = false
    ) {
        self.peerAddress = peerAddress
        self.link = link
        self.listenPort = listenPort
        self.wrapKeyHex = wrapKeyHex
        self.bond = bond
        self.streams = streams
        self.streamsPerCred = streamsPerCred
        self.readyTimeout = readyTimeout
        self.captchaSolver = captchaSolver
        self.manualCaptcha = manualCaptcha
    }
}

// MARK: - Core configuration

nonisolated extension TurnConfiguration {

    /// Field names are the `json` tags of `clientcore.Config` in the Go core.
    private struct CoreConfig: Encodable {
        let listen: String
        let peer_addr: String
        let vk_link: String
        let vless_mode: Bool
        let vless_bond: Bool
        let wrap_mode: Bool
        let wrap_key_hex: String
        let num_streams: Int
        let streams_per_cred: Int
        let captcha_solver: String
        let manual_captcha: Bool
        let debug: Bool
    }

    /// Builds the JSON the Go core is started with.
    ///
    /// `vless_mode` is always on: the outbound speaks TCP, and that is the mode
    /// where the core layers KCP and smux over DTLS and exposes a TCP listener.
    func makeCoreConfigJSON(debug: Bool = false) throws -> String {
        let config = CoreConfig(
            listen: listenAddress,
            peer_addr: peerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            vk_link: link.trimmingCharacters(in: .whitespacesAndNewlines),
            vless_mode: true,
            vless_bond: bond,
            wrap_mode: !wrapKeyHex.isEmpty,
            wrap_key_hex: wrapKeyHex,
            num_streams: streams,
            streams_per_cred: streamsPerCred,
            captcha_solver: captchaSolver,
            manual_captcha: manualCaptcha,
            debug: debug
        )
        let data = try JSONEncoder().encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TurnError.subscription(.noConfigurations)
        }
        return json
    }
}
