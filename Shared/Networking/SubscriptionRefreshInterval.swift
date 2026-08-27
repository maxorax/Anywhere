//
//  SubscriptionRefreshInterval.swift
//  Turn
//

import Foundation

/// How often subscriptions re-fetch themselves in the background.
///
/// A subscription is a live document: servers get added, keys rotate, quotas
/// reset. Refreshing only when the user remembers to pull the button means
/// connecting to servers that no longer exist.
nonisolated enum SubscriptionRefreshInterval: Int, Codable, Sendable, CaseIterable, Identifiable {
    case off = 0
    case sixHours = 6
    case twelveHours = 12
    case daily = 24
    case weekly = 168

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off:         String(localized: "Off")
        case .sixHours:    String(localized: "Every 6 Hours")
        case .twelveHours: String(localized: "Every 12 Hours")
        case .daily:       String(localized: "Daily")
        case .weekly:      String(localized: "Weekly")
        }
    }

    var duration: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue) * 3600
    }

    /// Whether a subscription last fetched at `lastUpdate` is now stale.
    /// A subscription that has never been fetched always is.
    func isStale(lastUpdate: Date?, now: Date = .now) -> Bool {
        guard let duration else { return false }
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= duration
    }
}
