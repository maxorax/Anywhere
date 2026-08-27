//
//  TurnCore.swift
//  Turn Network Extension
//

import Foundation
import Mobile
import UserNotifications

/// Owns the single VK TURN proxy instance living inside the tunnel process.
///
/// The core keeps package-level state in Go, so only one may run at a time —
/// hence the actor and the singleton. `activate` is idempotent for an unchanged
/// configuration, so switching between two proxies that share a relay does not
/// tear it down and build it back up.
actor TurnCore {
    static let shared = TurnCore()

    /// How often the phase monitor re-reads core state. Short enough that a
    /// captcha prompt reaches the journal while the user is still watching.
    private static let pollInterval = Duration.milliseconds(500)

    /// Floor for how long to wait on the listener.
    ///
    /// The core throttles its VK credential fetches to stay under the rate limit,
    /// so a cold start costs several seconds per batch — `streams / streamsPerCred`
    /// of them. Subscriptions tend to carry a far more optimistic `ready_timeout`
    /// than that path can meet.
    private static let minimumReadyTimeout = 120

    private let turn = IosNewTurn()
    /// The configuration the relay is serving, once its listener accepts.
    private var active: TurnConfiguration?
    /// A configuration whose core is still starting after a wait timed out. It is
    /// left running on purpose, so a retry can adopt it instead of discarding the
    /// credentials it has already collected.
    private var pending: TurnConfiguration?
    /// The configuration whose core is being brought up right now.
    ///
    /// `active` is only assigned once the listener accepts, and `startAndWait`
    /// can sit for a couple of minutes before that — the captcha phase happens
    /// inside the wait. Without this marker the relay reads as idle exactly when
    /// the app has to raise its captcha, and the connection waits on a prompt
    /// nobody was shown.
    private var starting: TurnConfiguration?
    private var logSink: TurnLogSink?
    private var monitor: Task<Void, Never>?
    private let logger = TurnLogger(category: "TurnCore")

    private init() {}

    /// Brings the relay up and returns the local endpoint the outbound should
    /// dial instead of the real server.
    func activate(_ configuration: TurnConfiguration) async throws -> (host: String, port: UInt16) {
        let endpoint = ("127.0.0.1", configuration.resolvedListenPort)

        if active == configuration, turn?.isRunning() == true {
            logger.info("[TURN] Relay already up for this proxy, reusing \(endpoint.0):\(endpoint.1)")
            return endpoint
        }

        // A previous attempt timed out but its core kept working — if it has come
        // up since, take it rather than starting over.
        if pending == configuration, turn?.isRunning() == true {
            let snapshot = state
            if snapshot.phase == .ready {
                logger.info("[TURN] Relay from the previous attempt is ready now — \(snapshot.summary)")
                active = configuration
                pending = nil
                return endpoint
            }
            logger.info("[TURN] Relay from the previous attempt is still starting — \(snapshot.summary)")
            throw TurnError.tunnel(.invalidConfiguration)
        }

        if active != nil || pending != nil {
            logger.info("[TURN] Configuration changed, restarting the relay")
            stopCore()
        }

        installLogSink()

        logger.info("[TURN] peer=\(configuration.peerAddress) listen=\(configuration.listenAddress) "
                    + "wrap=\(configuration.wrapKeyHex.isEmpty ? "off" : maskKey(configuration.wrapKeyHex)) "
                    + "bond=\(configuration.bond) streams=\(configuration.streams) "
                    + "streamsPerCred=\(configuration.streamsPerCred) "
                    + "solver=\(configuration.captchaSolver) timeout=\(configuration.resolvedReadyTimeout)s")
        logger.info("[TURN] vk link=\(maskLink(configuration.link))")

        let json = try configuration.makeCoreConfigJSON()
        let seconds = max(configuration.resolvedReadyTimeout, Self.minimumReadyTimeout)
        let timeout = seconds * 1000

        starting = configuration
        startMonitor()
        logger.info("[TURN] Starting core, waiting up to \(seconds)s for the listener "
                    + "(subscription asked for \(configuration.resolvedReadyTimeout)s)")

        // startAndWait blocks its thread until the listener accepts, so it must
        // not run on a cooperative-pool thread that the tunnel also needs.
        let failure: String = await withCheckedContinuation { continuation in
            let turn = self.turn
            Thread.detachNewThread {
                let result = turn?.startAndWait(json, timeoutMillis: timeout) ?? "TURN core unavailable"
                continuation.resume(returning: result)
            }
        }

        guard failure.isEmpty else {
            logger.error("[TURN] Core did not come up: \(failure)")
            logger.error("[TURN] Last state: \(state.summary)")
            // Left running on purpose — see `pending`. Reconnecting adopts it.
            starting = nil
            pending = configuration
            active = nil
            throw TurnError.tunnel(.invalidConfiguration)
        }

        starting = nil
        active = configuration
        pending = nil
        logger.info("[TURN] Listener accepting on \(endpoint.0):\(endpoint.1)")
        return endpoint
    }

    func deactivate() {
        // `isRunning` is part of the test on purpose: an `activate` that finished
        // after we had already decided to go direct leaves a core running with
        // nothing tracking it, and only the core itself still knows.
        guard active != nil || pending != nil || starting != nil || turn?.isRunning() == true else { return }
        logger.info("[TURN] Stopping the relay")
        stopCore()
    }

    var state: TurnState {
        // The Go core is a long-lived singleton and keeps reporting the last
        // phase it reached — `captcha` included — after it has been stopped. So
        // the phase is only meaningful while a relay is in play: starting up,
        // serving, or left running after a timed-out wait. Reporting it
        // unconditionally put a captcha prompt in front of users connecting
        // directly over Wi-Fi.
        guard active != nil || pending != nil || starting != nil else { return .idle }

        guard let json = turn?.stateJSON(), let data = json.data(using: .utf8) else {
            return .idle
        }
        return (try? JSONDecoder().decode(TurnState.self, from: data)) ?? .idle
    }

    /// Pins the relay's own sockets to a physical interface so they leave the
    /// device instead of looping back into the tunnel this process runs.
    func bind(toInterface name: String) {
        let index = turn?.setBindInterface(name) ?? 0
        logger.info("[TURN] Bound relay sockets to \(name) (index \(index))")
    }

    // MARK: - Monitoring

    /// Narrates every phase change to the journal. The core reports readiness
    /// and captcha prompts through state rather than a callback, so without this
    /// the only evidence a captcha is waiting would be a stalled connection.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var last: TurnState.Phase?
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.state
                if snapshot.phase != last {
                    last = snapshot.phase
                    await self.report(snapshot)
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func report(_ snapshot: TurnState) {
        switch snapshot.phase {
        case .idle:
            logger.info("[TURN] Idle — \(snapshot.summary)")
        case .connecting:
            logger.info("[TURN] Connecting, pulling relay credentials from VK — \(snapshot.summary)")
        case .captcha:
            logger.warning("[TURN] VK is asking for a captcha at \(snapshot.captchaUrl ?? "http://127.0.0.1:8765") "
                           + "— \(snapshot.summary)")
            notifyCaptchaWaiting()
        case .ready:
            logger.info("[TURN] Ready, traffic now goes through VK — \(snapshot.summary)")
            clearCaptchaNotification()
        case .stopped:
            logger.info("[TURN] Stopped — \(snapshot.summary)")
        case .error:
            logger.error("[TURN] Failed — \(snapshot.summary)")
        }

        // The extension cannot present UI. Every transition is announced so the
        // app can raise a WebView on the captcha page — and take it away again
        // once the core moves on.
        AWNotificationCenter.notifyTurnStateChanged()
    }

    // MARK: - Notifications

    /// Identifier is fixed so a second prompt replaces the first rather than
    /// stacking up.
    private static let captchaNotificationID = "turn.captcha"

    /// Puts a local notification on the lock screen when VK wants a captcha.
    ///
    /// The relay can be brought up while the app is in the background — walking
    /// out of Wi-Fi range does exactly that — and the captcha page can only be
    /// solved inside the app. Without a nudge the connection would just sit there
    /// looking broken.
    private func notifyCaptchaWaiting() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "VK captcha required")
        content.body = String(localized: "Open Turn to solve it and finish connecting through VK.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: Self.captchaNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.warning("[TURN] Could not post the captcha notification: \(error.localizedDescription)")
            }
        }
    }

    private func clearCaptchaNotification() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.captchaNotificationID])
    }

    // MARK: - Private

    private func stopCore() {
        monitor?.cancel()
        monitor = nil
        turn?.stop()
        starting = nil
        active = nil
        pending = nil
    }

    private func installLogSink() {
        guard logSink == nil else { return }
        let sink = TurnLogSink()
        logSink = sink
        turn?.setLogSink(sink)
    }

    /// Keys and call links end up in logs the user may share, so only enough to
    /// tell two of them apart survives.
    private func maskKey(_ key: String) -> String {
        key.count <= 8 ? key : "\(key.prefix(8))…(\(key.count) chars)"
    }

    private func maskLink(_ link: String) -> String {
        guard let slash = link.lastIndex(of: "/"), slash < link.endIndex else { return link }
        let token = link[link.index(after: slash)...]
        return link.replacingOccurrences(of: token, with: "\(token.prefix(6))…")
    }
}

/// Bridges Go log lines into the extension's logger.
///
/// Everything the core says goes to the journal verbatim. The core is the only
/// witness to whether traffic actually left through a VK relay, so losing its
/// narration would defeat the point of having it.
private final class TurnLogSink: NSObject, IosCallbackProtocol {
    private let logger = TurnLogger(category: "TurnCore")

    func onLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        logger.info("[TURN] \(message)")
    }

    func onStatus(_ status: String?) {
        guard let status, !status.isEmpty else { return }
        logger.info("[TURN] status: \(status)")
    }
}
