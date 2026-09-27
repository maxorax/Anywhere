//
//  TurnCore.swift
//  Turn Network Extension
//

import Foundation
import Mobile
import Synchronization
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

    /// Whether the core is asked to narrate what its lanes are doing.
    ///
    /// Which credential cache a lane took, which TURN server it landed on, when
    /// it rotated away from one, when a lane's session came up — all of it sits
    /// behind the core's debug flag, and it is the only view into the lanes
    /// there is. Debug builds get it. Release stays quiet on purpose: the
    /// journal is meant to be shareable, and these lines carry relay addresses.
#if DEBUG
    private static let coreDebugLogging = true
#else
    private static let coreDebugLogging = false
#endif

    /// The KCP window the core is held to, in packets each way.
    ///
    /// With lanes no longer bonded, this is what caps a single connection: 128
    /// packets at a 1200-byte MTU is 154 KB in flight, about 1.5 MB/s per
    /// connection at the 100 ms it takes to reach a VK relay. It also scales with
    /// lane count — 307 KB a lane across both directions — so widening it and
    /// adding lanes pull on the same budget.
    ///
    /// 256 was tried and taken back out. The relay's own numbers barely moved —
    /// 13.6 Mbit/s against 11.8 at peak — but the core runs KCP with congestion
    /// control off, so the window is less a limit on data in flight than on the
    /// size of a burst, and doubling it doubled what lands on one VK allocation
    /// at once. Individual connections stalled while the aggregate still looked
    /// healthy. Widening this again means turning congestion control on with it
    /// (`VK_TURN_KCP_NC=0`), not on its own.
    ///
    /// None of this reaches the core. Proven on device: Go copies the environment
    /// when the framework loads, which is before any of this runs, so `os.Getenv`
    /// reads a copy that will never contain it — the core has always used its own
    /// defaults, a 512-packet window included. Left in place because the values
    /// are the ones we want and the plumbing is what has to change: a setter on
    /// the gomobile bridge, or a field in the config JSON the core already parses.
    /// Until then, treat every number here as a wish rather than a setting.
    private static let coreMemoryBudget = [
        "VK_TURN_KCP_SNDWND": "128",
        "VK_TURN_KCP_RCVWND": "128",
    ]

    /// Floor for how long to wait on the listener.
    ///
    /// The core throttles its VK credential fetches to stay under the rate limit,
    /// so a cold start costs several seconds per batch — `streams / streamsPerCred`
    /// of them. Subscriptions tend to carry a far more optimistic `ready_timeout`
    /// than that path can meet.
    private static let minimumReadyTimeout = 120

    /// Whether traffic is going through the relay right now.
    ///
    /// The TCP path has to know this while deciding a route, and it cannot wait
    /// on this actor to ask — so the answer lives outside the isolation and
    /// mirrors `active`, which is the only thing that means "the listener is
    /// serving this configuration".
    nonisolated static let relaying = Atomic<Bool>(false)

    private let turn = IosNewTurn()
    /// The configuration the relay is serving, once its listener accepts.
    private var active: TurnConfiguration? {
        didSet { Self.relaying.store(active != nil, ordering: .relaxed) }
    }
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

        // Set before the core builds its first session — that is when it reads
        // them — and re-applied on every activation so a relay that outlives a
        // configuration change cannot end up on stale numbers.
        for (name, value) in Self.coreMemoryBudget {
            setenv(name, value, 1)
        }

        let json = try configuration.makeCoreConfigJSON(debug: Self.coreDebugLogging)
        // Stated rather than assumed: a session with no per-lane narration is
        // ambiguous — either the core was told to stay quiet, or the traffic
        // never reached it. This line settles which.
        logger.info("[TURN] Core debug logging: \(Self.coreDebugLogging ? "on" : "off")")
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
        guard var snapshot = try? JSONDecoder().decode(TurnState.self, from: data) else { return .idle }

        // The bridge reports a phase but says nothing about the lanes, and
        // `ready` only means the listener accepts — it can accept while half the
        // lanes are still failing to allocate. So the counts are attached here:
        // what was asked for, and what the core last said was up.
        let asked = (active ?? starting ?? pending)?.streams ?? 0
        snapshot.streams = asked > 0 ? asked : nil
        snapshot.activeStreams = logSink?.activeStreams.withLock { $0 }
        return snapshot
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
        // Nothing is carrying traffic once the core is down, and the sink
        // outlives it — a stale count would otherwise sit in Settings.
        logSink?.activeStreams.withLock { $0 = 0 }
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
    /// How many lanes the core last reported as carrying traffic.
    ///
    /// Scraped rather than asked for: the core publishes its session pool only
    /// in `[session 3] connected (active: 7)` and the matching `disconnected`
    /// line, and neither the bridge's `State` nor any other call exposes it.
    /// Written from Go's own threads, so it lives behind a lock.
    let activeStreams = Mutex<Int>(0)

    private let logger = TurnLogger(category: "TurnCore")

    func onLog(_ message: String?) {
        StackHeadroom.check(.coreLog)
        guard let message, !message.isEmpty else { return }
        guard let message = Self.redacted(message) else { return }
        // Straight to the journal's buffer, not through TurnLogger: this runs on
        // Go's threads, and four crash reports end right here, in that logger's
        // chain of closures, with the stack spent. The line no longer reaches
        // os_log; the journal is where it is read.
        TunnelStack.enqueueLine("[TURN] \(message)", level: .info)
        if let count = Self.laneCount(in: message) {
            activeStreams.withLock { $0 = count }
        }
    }

    /// Strips the captcha proxy's payloads out of the journal.
    ///
    /// The core narrates every request the captcha WebView makes, headers and
    /// bodies included — which means VK session tokens and cookies, in a file
    /// meant to be shared. The proxy's own progress is worth keeping, so the
    /// lines survive with everything after the payload marker cut off. Returns
    /// `nil` for a line that is nothing but headers.
    private static func redacted(_ message: String) -> String? {
        guard message.contains("[Captcha Proxy]") else { return message }
        if message.contains("] Header (") { return nil }
        for marker in [" data: ", " data:"] where message.contains(marker) {
            guard let cut = message.range(of: marker) else { continue }
            return message[..<cut.lowerBound] + " data: <redacted>"
        }
        return message
    }

    /// Reads the `(active: N)` the core prints whenever a lane comes up or drops.
    private static func laneCount(in message: String) -> Int? {
        guard let marker = message.range(of: "(active: ") else { return nil }
        let digits = message[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    func onStatus(_ status: String?) {
        guard let status, !status.isEmpty else { return }
        logger.info("[TURN] status: \(status)")
    }
}
