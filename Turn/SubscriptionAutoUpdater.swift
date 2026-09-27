//
//  SubscriptionAutoUpdater.swift
//  Turn
//

import Foundation
import Observation

/// Re-fetches subscriptions when the app is opened.
///
/// iOS gives a VPN app no dependable periodic wake-up, and the moment the app
/// comes to the foreground is when its subscriptions are about to be used — so
/// that is when they are refreshed. It used to refresh only what was older than
/// a day, which in practice meant the user never saw it happen; now everything
/// is refreshed on each opening, unless the setting is off. A subscription
/// fetched in the last few minutes is left alone, so switching apps back and
/// forth does not hammer the panel.
@MainActor
@Observable
final class SubscriptionAutoUpdater {
    static let shared = SubscriptionAutoUpdater()

    /// Subscriptions being refreshed right now, so the UI can show progress.
    private(set) var refreshing: Set<UUID> = []

    /// Anything fetched more recently than this is fresh enough.
    private static let minimumAge: TimeInterval = 10 * 60

    private var inFlight: Task<Void, Never>?
    private let logger = TurnLogger(category: "SubscriptionAutoUpdater")

    private init() {}

    /// Refreshes every subscription not fetched in the last few minutes, if
    /// refreshing on open is enabled. Safe to call often — overlapping runs
    /// collapse into the first. Each fetch carries its own deadline, so a run
    /// always ends and the spinners with it.
    func refreshOnOpen() {
        guard AWCore.getSubscriptionRefreshOnOpen() else { return }
        guard inFlight == nil else { return }

        let store = SubscriptionStore.shared
        let now = Date()
        let due = store.subscriptions.filter { subscription in
            guard !subscription.url.isEmpty else { return false }
            guard let last = subscription.lastUpdate else { return true }
            return now.timeIntervalSince(last) >= Self.minimumAge
        }
        guard !due.isEmpty else { return }

        logger.info("Refreshing \(due.count) subscription(s) on open")

        inFlight = Task { [weak self] in
            defer { self?.inFlight = nil }
            for subscription in due {
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
