//
//  ProviderMessageConcurrencyBridge.swift
//  Turn
//
//  Created by NodePassProject on 7/17/26.
//

import NetworkExtension

nonisolated enum ProviderMessageConcurrencyBridge {
    /// How long to wait for the extension to answer.
    ///
    /// `sendProviderMessage` calls back only if the extension answers, and an
    /// extension that is restarting, has crashed, or is stuck in a handler never
    /// does — which left a latency test spinning for as long as the app was open.
    static let replyTimeout: TimeInterval = 15

    static func send(_ messageData: Data, over session: NETunnelProviderSession,
                     timeout: TimeInterval = replyTimeout) async -> Data? {
        await withCheckedContinuation { continuation in
            // Whichever comes first — the reply or the deadline — resumes; the
            // other finds the claim taken and does nothing.
            let once = RaceClaim()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
            do {
                try session.sendProviderMessage(messageData) { response in
                    if once.claim() { continuation.resume(returning: response) }
                }
            } catch {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}
