//
//  SubscriptionAutoUpdater.swift
//  Turn
//

import Foundation
import Observation

/// Re-fetches subscriptions that have gone stale.
///
/// iOS gives a VPN app no dependable periodic wake-up, so rather than pretend to
/// run a timer this checks whenever the app comes to the foreground and refreshes
/// only what is actually overdue. In practice that is often enough: a
/// subscription is consulted when the user opens the app to connect.
@MainActor
@Observable
final class SubscriptionAutoUpdater {
    static let shared = SubscriptionAutoUpdater()

    /// Names currently being refreshed, so the UI can show progress.
    private(set) var refreshing: Set<UUID> = []

    private var inFlight: Task<Void, Never>?
    private let logger = TurnLogger(category: "SubscriptionAutoUpdater")

    private init() {}

    /// Refreshes every subscription older than the configured interval. Safe to
    /// call often — overlapping runs collapse into the first.
    func refreshStaleSubscriptions() {
        let interval = AWCore.getSubscriptionRefreshInterval()
        guard interval != .off else { return }
        guard inFlight == nil else { return }

        let store = SubscriptionStore.shared
        let stale = store.subscriptions.filter {
            !$0.url.isEmpty && interval.isStale(lastUpdate: $0.lastUpdate)
        }
        guard !stale.isEmpty else { return }

        logger.info("Refreshing \(stale.count) stale subscription(s), interval \(interval.title)")

        inFlight = Task { [weak self] in
            defer { self?.inFlight = nil }
            for subscription in stale {
                guard !Task.isCancelled else { return }
                self?.refreshing.insert(subscription.id)
                do {
                    try await store.refresh(subscription)
                    self?.logger.info("Refreshed \"\(subscription.name)\"")
                } catch {
                    // A failed refresh keeps the previous servers, so this is not
                    // worth interrupting the user over.
                    self?.logger.warning("Could not refresh \"\(subscription.name)\": \(error.localizedDescription)")
                }
                self?.refreshing.remove(subscription.id)
            }
        }
    }
}
