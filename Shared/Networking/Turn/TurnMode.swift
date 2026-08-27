//
//  TurnMode.swift
//  Turn
//

import Foundation

/// When to relay through VK Calls TURN instead of dialling the server directly.
///
/// Relaying costs latency and a VK call, so it is worth doing only where the
/// direct path is actually blocked. On Wi-Fi that is rarely the case; on a
/// carrier network it often is, and the operators that block VLESS tend to leave
/// VK reachable — frequently zero-rated.
nonisolated enum TurnMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Wi-Fi goes direct. On cellular the direct path is probed first and the
    /// relay is used only when that probe fails.
    case auto
    /// Relay everywhere, without probing.
    case always
    /// Never relay, even where the subscription offers one.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:   String(localized: "Automatic")
        case .always: String(localized: "Always")
        case .off:    String(localized: "Off")
        }
    }

    var caption: String {
        switch self {
        case .auto:
            String(localized: "Direct on Wi-Fi. On cellular, relay only if the direct path is unreachable.")
        case .always:
            String(localized: "Always relay through VK Calls, on any network.")
        case .off:
            String(localized: "Never relay, even when the subscription offers one.")
        }
    }
}
