//
//  TunnelStack+Lifecycle.swift
//  Turn
//
//  Created by NodePassProject on 3/30/26.
//

import Foundation
import NetworkExtension
import Synchronization

nonisolated private let logger = TurnLogger(category: "TunnelStack+Lifecycle")

extension TunnelStack {

    // MARK: - Lifecycle
    
    /// Routes `TurnLogger` into the user-facing journal.
    ///
    /// Split out of `start` because work that happens before the stack comes up —
    /// bringing the VK TURN relay online, above all — has to be visible too, and
    /// anything logged before this runs reaches only the system log.
    /// Installing twice is harmless; the sink is simply replaced.
    /// Nothing in here runs on the thread that logged the line, and nothing is
    /// dispatched per line either.
    ///
    /// Six crash reports explain the first half: the same stack overflow on
    /// `com.maxorax.turn.lwip`, a packet-handling thread with a small stack,
    /// reached through four different callers. The sink is expensive — a dozen
    /// reabstraction frames before any work starts, and `Data(line.utf8)` then
    /// reaches through `swift_dynamicCast` into dyld's conformance walk — so it
    /// has to happen somewhere with room for it.
    ///
    /// The journal explains the second half. Handing each line to a queue fixed
    /// the overflow and bought a new failure: six sessions died silently after
    /// 5649, 5667, 5671, 5673, 5674 and 5674 lines — a constant count, while
    /// their durations ranged from seventeen minutes to nearly eight hours and
    /// their rates from twelve to a hundred and eighty lines a minute. No crash
    /// report, no jetsam event, and `phys_footprint` flat at 22–30 MB against a
    /// limit of fifty, so whatever ran out was not memory. One dispatch per line
    /// was the only thing counting up with the line count, so there is no longer
    /// one: lines go into a buffer, and a single long-lived thread drains it.
    private struct PendingLine: Sendable {
        let message: String
        let level: TunnelLogLevel
        let moment: Date
    }

    /// A weak handle rather than a captured `self`: the pump outlives any one
    /// stack, and must not be what keeps a dead one alive.
    private struct PumpTarget: @unchecked Sendable {
        weak var stack: TunnelStack?
    }

    private static let pendingLines = Mutex<[PendingLine]>([])
    private static let linesReady = DispatchSemaphore(value: 0)
    private static let pumpTarget = Mutex(PumpTarget())
    private static let pumpStarted = Mutex(false)

    /// Ceiling on the backlog. A pump that falls behind drops lines rather than
    /// growing without bound — the journal is a diagnostic, not the tunnel.
    private static let maximumPending = 4096

    nonisolated func installLogSink() {
        Self.pumpTarget.withLock { $0.stack = self }
        Self.startLogPump()

        TurnLogger.installLogSink { message, level in
            let logLevel: TunnelLogLevel
            switch level {
            case .debug, .info: logLevel = .info
            case .warning: logLevel = .warning
            case .error: logLevel = .error
            }
            Self.enqueueLine(message, level: logLevel)
        }
    }

    /// Hands a line to the journal's pump and returns. Callable from any thread
    /// — the Go core's own threads included, which call it directly rather than
    /// through `TurnLogger`: that path costs a dozen reabstraction frames, an
    /// os_log and a closure fetched from a lock, on threads whose stack has run
    /// out in every crash report so far.
    nonisolated static func enqueueLine(_ message: String, level: TunnelLogLevel) {
        StackHeadroom.check(.logSink)
        // Stamped here so the file records when the line happened rather than
        // when the pump reached it.
        let line = PendingLine(message: message, level: level, moment: Date())
        let wake = pendingLines.withLock { buffer -> Bool in
            guard buffer.count < maximumPending else { return false }
            buffer.append(line)
            // Only the line that finds the buffer empty needs to wake the pump;
            // the rest are already covered by that signal.
            return buffer.count == 1
        }
        if wake { linesReady.signal() }
    }

    private static func startLogPump() {
        let shouldStart = pumpStarted.withLock { started -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        // `installLogSink` is called twice on every start — once by the provider
        // and once by `start` below — and the pump is process-wide.
        guard shouldStart else { return }

        let pump = Thread {
            while true {
                linesReady.wait()
                while !writePendingLines().isEmpty {}
            }
        }
        pump.name = "com.maxorax.turn.logPump"
        pump.qualityOfService = .utility
        pump.start()
    }

    /// Takes whatever is waiting and writes it. Returns what it wrote, so the
    /// pump can keep going until the buffer is actually empty.
    @discardableResult
    private static func writePendingLines() -> [PendingLine] {
        let batch = pendingLines.withLock { buffer -> [PendingLine] in
            let out = buffer
            buffer.removeAll(keepingCapacity: true)
            return out
        }
        guard !batch.isEmpty else { return batch }
        let stack = pumpTarget.withLock { $0.stack }
        for line in batch {
            stack?.appendLog(line.message, level: line.level)
            // Same line to disk: the in-memory journal above is unreachable once
            // this process is gone, and a killed extension is exactly the case
            // worth reading afterwards.
            TunnelLogFile.shared.append(line.message, level: line.level, at: line.moment)
        }
        return batch
    }

    /// Writes everything already logged, on the caller's thread.
    ///
    /// `stopTunnel` has seconds before the process ends, and the lines saying
    /// why it stopped are exactly the ones worth keeping. Safe to call from
    /// there — it is an ordinary async context, not the shallow packet thread
    /// the pump exists to protect.
    static func flushPendingLogs() {
        writePendingLines()
    }

    func start(packetFlow: NEPacketTunnelFlow, configuration: ProxyConfiguration) async {
        installLogSink()
        self.packetFlow = packetFlow
        self.configuration = configuration

        let udpPlane = UDPPlane(stack: self)
        self.udpPlane = udpPlane

        running.store(true, ordering: .relaxed)

        var precompiledRouting: DomainRouter.CompiledRouting?
        if Self.effectiveProxyMode(settings: TunnelSettings.load(), network: networkContext) == .rule {
            precompiledRouting = await domainRouter.compileRoutingConfiguration()
        }
        configureRuntime(for: configuration, precompiledRouting: precompiledRouting)

        installLwipCallbacks()
        lwip_bridge_init()
        startTimeoutTimer()
        
        rootTask = Task { await self.run(packetFlow: packetFlow, udpPlane: udpPlane) }
        
        logger.debug("[TunnelStack] Started")

        CertificatePolicy.startObserving()
    }

    // MARK: - Task tree
    
    private func run(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { [planeCommands] in
                for await command in planeCommands {
                    await udpPlane.apply(command)
                }
            }
            group.addTask {
                await self.runDutyCycle(packetFlow: packetFlow, udpPlane: udpPlane)
                await self.finishShutdown()
            }
        }
    }
    
    private func runDutyCycle(packetFlow: NEPacketTunnelFlow, udpPlane: UDPPlane) async {
        await withDiscardingTaskGroup { group in
            group.addTask { [outputKick] in
                for await _ in outputKick {
                    await self.drainOutputLoop(packetFlow: packetFlow)
                }
            }
            group.addTask { await self.runReadLoop(packetFlow: packetFlow, udpPlane: udpPlane) }
            group.addTask { await self.runSettingsObserver() }
            group.addTask { await self.runUDPCleanupLoop(udpPlane: udpPlane) }
            for await job in self.nurseryJobs {
                switch job {
                case .deferredRestart(let configuration, let revalidateMode, let delay, let generation):
                    group.addTask {
                        await self.runDeferredRestart(
                            configuration: configuration,
                            revalidateMode: revalidateMode,
                            delay: delay,
                            generation: generation
                        )
                    }
                }
            }
            group.cancelAll()
        }
    }
    
    private func finishShutdown() {
        shutdownInternal()
        lwip_bridge_set_host_ctx(nil)
        OutboundConnector.setRoutingContext(nil)
        fakeIPPool.reset()
        connectionRouter.clearRejectMarks()
        ConnectionMetrics.shared.setDefaultServer(nil)
        configuration = nil
        finishPlaneCommands()
    }
    
    func stop() async {
        running.store(false, ordering: .relaxed)
        nurseryJobContinuation.finish()
        await rootTask?.value
        rootTask = nil
        TurnLogger.installLogSink(nil)
    }
    
    func switchConfiguration(_ newConfiguration: ProxyConfiguration) {
        // Both callers reach here through `prepared`, which hands back the very
        // same configuration whenever the relay decision has not moved.
        // Restarting on that tears down every open connection only to rebuild an
        // identical stack.
        guard newConfiguration != configuration else {
            logger.debug("[VPN] Configuration unchanged — keeping the stack up")
            return
        }
        logger.info("[VPN] Configuration switched")
        restartStack(configuration: newConfiguration)
    }
    
    func handleWake() {
        guard running.load(ordering: .relaxed), let configuration else { return }
        logger.info("[VPN] Device wake")
        invalidateOutboundState(configuration: configuration)
    }
    
    func suspendOutbound() {
        guard running.load(ordering: .relaxed) else { return }
        logger.info("[VPN] Path offline/sleep")

        reclaimAllOutboundPools()
        reclaimInstanceTransports(rebuildMultiplexerPool: false)
    }
    
    /// Seeds the network context before the stack comes up.
    ///
    /// `updateNetworkContext` deliberately ignores anything arriving before the
    /// stack runs, and the path monitor only starts after `start` — so without
    /// this both the first relay decision and the initial proxy mode are made
    /// against a default context that claims neither Wi-Fi nor cellular.
    func seedNetworkContext(isWiFi: Bool, isCellular: Bool, ssid: String?) {
        guard !running.load(ordering: .relaxed) else { return }
        networkContext = NetworkContext(isWiFi: isWiFi, isCellular: isCellular, ssid: ssid)
    }

    func updateNetworkContext(isWiFi: Bool, isCellular: Bool, ssid: String?) {
        guard running.load(ordering: .relaxed), let configuration else { return }

        let context = NetworkContext(isWiFi: isWiFi, isCellular: isCellular, ssid: ssid)
        guard context != networkContext else { return }
        networkContext = context

        let newEffective = computeEffectiveProxyMode()
        guard newEffective != proxyMode else { return }
        logger.info("[VPN] Trusted-network policy: effective mode \(proxyMode.rawValue) → \(newEffective.rawValue) (Wi-Fi=\(isWiFi), cellular=\(isCellular), SSID=\(ssid ?? "—"))")
        restartStack(configuration: configuration, revalidateMode: true)
    }
    
    private func invalidateOutboundState(configuration: ProxyConfiguration) {
        closeAllActiveTCP()
        reclaimAllOutboundPools()
        reclaimInstanceTransports(rebuildMultiplexerPool: true)
    }
    
    private func closeAllActiveTCP() {
        lwip_bridge_for_each_tcp { arg in
            guard let arg else { return }
            BridgeContext.unretained(arg, as: TCPConnection.self).assumeIsolated { $0.close() }
        }
    }
    
    private func reclaimAllOutboundPools() {
        TransportReclaim.reclaimAll()
        MITMScriptHTTP2Pool.shared.reclaim()
    }
    
    private func reclaimInstanceTransports(rebuildMultiplexerPool: Bool) {
        let rebuiltMultiplexerPool: VLESSVisionUDPMultiplexerPool?
        if rebuildMultiplexerPool, let configuration, configuration.outboundProtocol == .vless {
            rebuiltMultiplexerPool = VLESSVisionUDPMultiplexerPool(configuration: configuration)
        } else {
            rebuiltMultiplexerPool = nil
        }
        submitPlaneCommand(.reclaim(replacementMultiplexerPool: rebuiltMultiplexerPool))
    }
    
    private func shutdownInternal() {
        lwipTick?.cancel()
        lwipTick = nil

        outputBuffer.withLock { buffer in
            buffer.packets.removeAll(keepingCapacity: true)
            buffer.protocols.removeAll(keepingCapacity: true)
            for r in buffer.releases {
                r.fn(r.ctx)
            }
            buffer.releases.removeAll(keepingCapacity: true)
            buffer.drainInFlight = false
        }

        reclaimAllOutboundPools()
        reclaimInstanceTransports(rebuildMultiplexerPool: false)

        isTearingDown.store(true, ordering: .relaxed)
        lwip_bridge_shutdown()
        isTearingDown.store(false, ordering: .relaxed)
        FlowGauge.publishTCPTable(0)
        logger.debug("[TunnelStack] Shutdown complete")
    }
    
    private func restartStack(configuration: ProxyConfiguration, revalidateMode: Bool = false) {
        if revalidateMode, deferredRestartScheduled { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRestartTime

        if elapsed < TunnelConstants.restartThrottleInterval {
            let delay = TunnelConstants.restartThrottleInterval - elapsed
            deferredRestartGeneration += 1
            deferredRestartScheduled = true
            nurseryJobContinuation.yield(.deferredRestart(
                configuration: configuration, revalidateMode: revalidateMode,
                delay: delay, generation: deferredRestartGeneration
            ))
            logger.debug("[TunnelStack] Restart throttled, deferred by \(String(format: "%.0f", delay * 1000))ms")
            return
        }

        restartStackNow(configuration: configuration)
    }
    
    private func runDeferredRestart(
        configuration: ProxyConfiguration,
        revalidateMode: Bool,
        delay: TimeInterval,
        generation: Int
    ) async {
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        guard generation == deferredRestartGeneration else { return }
        deferredRestartScheduled = false
        guard running.load(ordering: .relaxed) else { return }
        if revalidateMode, computeEffectiveProxyMode() == proxyMode { return }
        restartStackNow(configuration: configuration)
    }
    
    private func restartStackNow(configuration: ProxyConfiguration) {
        deferredRestartGeneration += 1
        deferredRestartScheduled = false
        lastRestartTime = CFAbsoluteTimeGetCurrent()

        shutdownInternal()
        
        connectionRouter.clearRejectMarks()

        self.configuration = configuration
        configureRuntime(for: configuration)
        installLwipCallbacks()
        lwip_bridge_init()
        startTimeoutTimer()
        logger.debug("[TunnelStack] Restarted")
    }

    // MARK: - Settings Observation
    
    private func runSettingsObserver() async {
        let settings = AWNotificationCenter.Notification.tunnelSettingsChanged as String
        let routing = AWNotificationCenter.Notification.routingChanged as String
        let mitm = AWNotificationCenter.Notification.mitmChanged as String
        for await name in DarwinNotificationConcurrencyBridge.names([
            AWNotificationCenter.Notification.tunnelSettingsChanged,
            AWNotificationCenter.Notification.routingChanged,
            AWNotificationCenter.Notification.mitmChanged
        ]) {
            switch name {
            case settings: handleSettingsChanged()
            case routing: await handleRoutingChanged()
            case mitm: handleMITMChanged()
            default: break
            }
        }
    }

    private func handleSettingsChanged() {
        guard running.load(ordering: .relaxed), let configuration else { return }

        let old = settings
        let new = TunnelSettings.load()
        guard new != old else { return }
        settings = new

        if new.quicPolicy != old.quicPolicy {
            logger.info("[VPN] QUIC policy changed: \(old.quicPolicy.rawValue) -> \(new.quicPolicy.rawValue)")
        }
        if new.blockUDP != old.blockUDP {
            logger.info("[VPN] Block UDP changed: \(old.blockUDP) -> \(new.blockUDP)")
        }
        if new.blockWebRTC != old.blockWebRTC {
            logger.info("[VPN] Block WebRTC changed: \(old.blockWebRTC) -> \(new.blockWebRTC)")
        }
        if new.preventDNSLeak != old.preventDNSLeak {
            logger.info("[VPN] Prevent DNS Leak changed: \(old.preventDNSLeak) -> \(new.preventDNSLeak)")
            connectionRouter.preventDNSLeak.store(new.preventDNSLeak, ordering: .relaxed)
        }
        if new.reflectionEnabled != old.reflectionEnabled || new.reflectionAddresses != old.reflectionAddresses {
            logger.info("[VPN] Reflection changed: enabled=\(new.reflectionEnabled), addresses=\(new.reflectionAddresses)")
            publishReflector()
        }
        if new.ipRuleDNSUpstream != old.ipRuleDNSUpstream {
            logger.info("[VPN] IP-rule DNS changed")
            RuleResolver.shared.setUpstream(new.ipRuleDNSUpstream)
        }
        if new.interceptExemptDNSServers != old.interceptExemptDNSServers {
            logger.info("[VPN] DNS interception exemptions changed: \(new.interceptExemptDNSServers.sorted())")
        }
        publishUDPConfig()
        
        if new.tunnelIncludedRoutes != old.tunnelIncludedRoutes || new.tunnelExcludedRoutes != old.tunnelExcludedRoutes {
            logger.info("[VPN] Custom routes changed: included=\(new.tunnelIncludedRoutes), excluded=\(new.tunnelExcludedRoutes)")
            requestReapplyTunnelSettings()
        }

        let proxyModeChanged = computeEffectiveProxyMode() != proxyMode
        let hideVPNIconChanged = new.hideVPNIcon != old.hideVPNIcon
        let advertiseIPv6ToAppsChanged = new.advertiseIPv6ToApps != old.advertiseIPv6ToApps

        guard proxyModeChanged || hideVPNIconChanged || advertiseIPv6ToAppsChanged else {
            return
        }

        logger.info("[VPN] Settings changed")
        
        if advertiseIPv6ToAppsChanged || hideVPNIconChanged {
            requestReapplyTunnelSettings()
        }

        restartStack(configuration: configuration)
    }
    
    private func handleRoutingChanged() async {
        guard running.load(ordering: .relaxed) else { return }
        guard proxyMode == .rule else { return }
        logger.info("[VPN] Routing changed")
        domainRouter.install(await domainRouter.compileRoutingConfiguration())
        connectionRouter.clearRejectMarks()
    }
    
    private func handleMITMChanged() {
        guard running.load(ordering: .relaxed) else { return }
        logger.info("[VPN] MITM settings changed")
        loadMITMSetting()
        publishUDPConfig()
    }
}
