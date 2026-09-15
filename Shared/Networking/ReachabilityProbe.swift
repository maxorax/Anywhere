//
//  ReachabilityProbe.swift
//  Turn
//

import Foundation
import Network
import Synchronization

nonisolated private let logger = TurnLogger(category: "ReachabilityProbe")

/// Decides what kind of network this is by asking three well-known hosts, in one
/// second, before anything is brought up.
///
/// The probe it replaces asked a different question — "can I reach my own server
/// directly" — and paid ten seconds of the connection's start-up to answer it,
/// because the answer needed a full Reality handshake to the real address. This
/// one asks what the network is doing to traffic in general: `google.com` is the
/// host that goes quiet under filtering, and `ya.ru` and `vk.com` are the control
/// group that stays up. Silence from all three is not censorship, it is no
/// network at all, and that is worth telling apart — relaying through VK costs a
/// call and a captcha, and neither is recoverable when there is nothing to dial.
///
/// A plain TCP connect is the test. ICMP needs raw sockets the extension has no
/// business holding, and filtering happens to TCP anyway. The known gap: a DPI
/// box that accepts the connection and answers in the host's place reads as
/// reachable here — telling those apart needs a TLS handshake with certificate
/// checking, which does not reliably fit in the budget.
nonisolated enum ReachabilityProbe {

    /// What the network turned out to be.
    enum Verdict: Sendable {
        /// The canary answers: nothing is being filtered, dial straight out.
        case open
        /// The canary is gone while the control group answers: filtered network.
        case censored
        /// Nobody answers. There is no network to relay over either.
        case offline
    }

    /// The host whose silence is the signal.
    private static let canary = "google.com"

    /// Hosts that stay reachable under filtering, so their silence means the
    /// network itself is down rather than censored.
    private static let controls = ["ya.ru", "vk.com"]

    private static let port = NWEndpoint.Port(rawValue: 443)!

    /// The whole probe, not each host — they run together.
    private static let budget: Duration = .seconds(1)

    private static let queue = DispatchQueue(label: "com.maxorax.turn.ReachabilityProbe")

    /// How many times "nothing answers" is retried before it is believed.
    ///
    /// The probe runs on the network having just changed, and a radio that has
    /// only now come up answers nothing at all — on device, a switch to cellular
    /// produced three silent hosts for the whole one-second budget, a verdict of
    /// "no network", and a session committed to a direct path that this carrier
    /// blocks. Only the negative answer is retried: whatever answered is
    /// reachable now, but nothing answering may only mean not yet.
    private static let offlineRetries = 2
    private static let retryDelay: Duration = .milliseconds(700)

    // MARK: - Probe

    static func run() async -> Verdict {
        for _ in 0..<offlineRetries {
            let verdict = await probeOnce()
            guard verdict == .offline else { return verdict }
            logger.info("[Probe] nothing answered; the network may still be settling, retrying")
            try? await Task.sleep(for: retryDelay)
        }
        return await probeOnce()
    }

    private static func probeOnce() async -> Verdict {
        let answers = await withTaskGroup(of: (host: String, alive: Bool).self) { group in
            for host in [canary] + controls {
                group.addTask { (host, await reachable(host)) }
            }
            var answers: [String: Bool] = [:]
            for await answer in group { answers[answer.host] = answer.alive }
            return answers
        }

        let summary = ([canary] + controls)
            .map { "\($0) \(answers[$0] == true ? "up" : "down")" }
            .joined(separator: ", ")

        if answers[canary] == true {
            logger.info("[Probe] \(summary) — network is open")
            return .open
        }
        // A single surviving control host is still a live network, and the canary
        // is already known to be gone, so there is nothing for a direct path to
        // do. Both alive is the clean case; one is a degraded version of it.
        if controls.contains(where: { answers[$0] == true }) {
            logger.info("[Probe] \(summary) — network is filtered")
            return .censored
        }
        logger.warning("[Probe] \(summary) — no network")
        return .offline
    }

    // MARK: - One host

    private static func reachable(_ host: String) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await settled(connection) }
            group.addTask {
                try? await Task.sleep(for: budget)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            connection.cancel()
            return first
        }
    }

    /// Resolves the moment the connection knows either way.
    ///
    /// `waiting` counts as a failure on purpose: it is what a blocked or routeless
    /// endpoint reports while it keeps retrying, and a probe with a one-second
    /// budget has no use for a retry that may land after the answer is needed.
    private static func settled(_ connection: NWConnection) async -> Bool {
        let answered = Mutex(false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { reachable in
                let isFirst = answered.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard isFirst else { return }
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled, .waiting:
                    finish(false)
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
