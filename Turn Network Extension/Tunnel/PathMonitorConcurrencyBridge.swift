//
//  PathMonitorConcurrencyBridge.swift
//  Turn
//
//  Created by NodePassProject on 7/17/26.
//

import Network
import NetworkExtension
import Synchronization

nonisolated final class PathMonitorConcurrencyBridge: Sendable {

    private let queue: DispatchQueue

    init() {
        self.queue = DispatchQueue(label: "com.maxorax.turn.PathMonitorConcurrencyBridge")
    }
    
    /// One-shot read of the current path, for seeding state before `paths()` is
    /// running.
    ///
    /// Returns `nil` if the monitor has not reported within `timeout` — this is
    /// awaited inside `startTunnel`, which the system kills if it takes too
    /// long, so it must never block indefinitely.
    func firstPath(timeout: Duration) async -> Network.NWPath? {
        await withTaskGroup(of: Network.NWPath?.self) { group in
            group.addTask {
                for await path in self.paths() { return path }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            // Cancelling the reader terminates the stream, which cancels its
            // monitor through `onTermination`.
            group.cancelAll()
            return first
        }
    }

    func paths() -> AsyncStream<Network.NWPath> {
        let queue = self.queue
        return AsyncStream(Network.NWPath.self, bufferingPolicy: .unbounded) { continuation in
            let monitor = NWPathMonitor()
            let previous = Mutex<Network.NWPath?>(nil)
            monitor.pathUpdateHandler = { path in
                let changed = previous.withLock { stored in
                    guard stored != path else { return false }
                    stored = path
                    return true
                }
                guard changed else { return }
                continuation.yield(path)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

#if os(iOS)
    func currentWiFiSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }
#endif
}
