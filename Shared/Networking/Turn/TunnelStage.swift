//
//  TunnelStage.swift
//  Turn
//

import Foundation

/// How far the tunnel has got in coming up, as the main screen draws it.
///
/// The relay reports its own phase through ``TurnState``, but everything before
/// it — picking the configuration, probing whether the direct path even needs a
/// relay, deciding which way to go — happened in silence inside the provider.
/// The flow chart on the main screen is a picture of exactly that sequence, so
/// the provider publishes where it is rather than letting the screen guess from
/// `VPNStatus` alone.
nonisolated enum TunnelStage: String, Codable, Sendable {
    /// Nothing is being brought up.
    case idle
    /// Configuration resolved and the tunnel's network settings applied.
    case profile
    /// Measuring the direct path to decide whether a relay is worth it. Only
    /// `auto` mode reaches this; `always` and `off` skip straight to `route`.
    case probe
    /// The way is chosen — ``TunnelPath`` says which.
    case route
    /// Bringing the VK relay up: credentials, allocations, lanes.
    case relay
    /// Traffic is flowing.
    case connected
    /// The attempt failed and the tunnel is not up.
    case failed

    /// Order along the chart's main line, for deciding what is already behind us.
    var rank: Int {
        switch self {
        case .idle, .failed: 0
        case .profile: 1
        case .probe: 2
        case .route: 3
        case .relay: 4
        case .connected: 5
        }
    }
}

/// Which way this connection goes once the route is decided.
nonisolated enum TunnelPath: String, Codable, Sendable {
    /// Straight to the proxy.
    case direct
    /// Through a VK Calls relay — the branch the chart draws to the right.
    case turn
}
