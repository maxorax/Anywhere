//
//  PacketTunnelProvider.swift
//  Turn
//
//  Created by NodePassProject on 1/23/26.
//

import NetworkExtension
import Network
import Synchronization
#if os(iOS)
import WidgetKit
#endif

nonisolated private let logger = TurnLogger(category: "PacketTunnelProvider")

nonisolated class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let tunnelStack = TunnelStack()
    private let statsRecorder = StatsRecorder()

    private let pathMonitorBridge = PathMonitorConcurrencyBridge()

    private let rootTask = Mutex<Task<Void, Never>?>(nil)

    /// The selected proxy as the app sent it — before any relay redirect. Kept so
    /// a network change can re-run the relay decision from the original.
    private let baseConfiguration = Mutex<ProxyConfiguration?>(nil)

    /// Interface the relay's sockets are currently pinned to, so a path update
    /// that changes nothing does not re-bind and re-log.
    private let boundInterface = Mutex<String?>(nil)

    /// Slow tick that writes the process footprint to the journal.
    private let memoryWatch = Mutex<Task<Void, Never>?>(nil)

    /// How far this start has got, and which way it went. The main screen draws
    /// the sequence, so the steps that used to happen in silence — resolving the
    /// configuration, probing the direct path, choosing the route — are reported
    /// rather than inferred from `VPNStatus`.
    private let stage = Mutex<TunnelStage>(.idle)
    private let path = Mutex<TunnelPath?>(nil)

    // MARK: - Tunnel Lifecycle
    
    override func startTunnel(options: [String : NSObject]? = nil) async throws {
        // Before anything else, so bringing the TURN relay up is narrated in the
        // journal rather than only in the system log.
        tunnelStack.installLogSink()

        guard let configuration = resolveStartConfiguration(options: options) else {
            let error = TurnError.tunnel(.invalidConfiguration)
            logger.report("[VPN] Start failed", error: error)
            throw error
        }

        let settings = buildTunnelSettings()

        do {
            try await setTunnelNetworkSettings(settings)
        } catch {
            let wrapped = TurnError.tunnel(.settingsApplyFailed(underlying: error))
            logger.report("[VPN]", error: wrapped)
            throw wrapped
        }

#if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: "com.maxorax.turn.Widget.VPNToggle")
#endif

        report(.profile)

        // Seed the network context before the first relay decision. The path
        // monitor starts with `run()` below, and `updateNetworkContext` drops
        // anything that arrives before the stack is up — so without this,
        // `shouldRelay` would classify every cold start as an unidentified
        // network and probe the direct path even on Wi-Fi.
        //
        // Apple's guidance is to leave `setTunnelNetworkSettings` until the
        // provider can forward packets, which would put this whole block first.
        // Tried, and it broke the relay: its sockets are established before the
        // tunnel exists, and applying a default route afterwards takes them
        // down. Shortening the wait is the way to close that window, not
        // reordering it.
        if let path = await pathMonitorBridge.firstPath(timeout: .seconds(2)) {
            let context = await networkContext(for: path)
            await tunnelStack.seedNetworkContext(
                isWiFi: context.isWiFi,
                isCellular: context.isCellular,
                ssid: context.ssid
            )
        } else {
            logger.warning("[VPN] Path monitor did not report in time — deciding on an unidentified network")
        }

        let effective = await prepared(configuration)
        await tunnelStack.start(packetFlow: packetFlow, configuration: effective)
        report(.connected)
        
        rootTask.withLock { task in
            guard task == nil else { return }
            task = Task { await self.run() }
        }
        
        startMemoryWatch()

        statsRecorder.start { [tunnelStack] in
            return StatsRecorder.RawValues(
                byteCounts: tunnelStack.byteCounts.withLock { $0 },
                tcpConnectionCount: FlowGauge.tcpTable,
                udpConnectionCount: FlowGauge.udpTable,
                memoryBytes: Self.memoryFootprint()
            )
        }
    }
    
    private func resolveStartConfiguration(options: [String: NSObject]?) -> ProxyConfiguration? {
        if let messageData = options?[TunnelMessage.optionKey] as? Data {
            do {
                if case .setConfiguration(let config) = try JSONDecoder().decode(TunnelMessage.self, from: messageData) {
                    return config
                }
            } catch {
                logger.report("[VPN] Start options decode failed", error: TurnError.tunnel(.ipcFailed(underlying: error)))
            }
        }
        guard let savedData = AWCore.getLastConfigurationData() else { return nil }
        do {
            return try JSONDecoder().decode(ProxyConfiguration.self, from: savedData)
        } catch {
            logger.report(TurnError.store(.corrupted(.configurations, detail: TurnError.describe(error))))
            return nil
        }
    }

    // MARK: - Tunnel Settings

    private func buildTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let tunnelAddressIPv4 = TunnelConstants.tunnelAddressIPv4
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelAddressIPv4)

        let hideVPNIcon = AWCore.getHideVPNIcon()
        let includedRoutes = Self.parseRoutes(AWCore.getTunnelIncludedRoutes())
        let excludedRoutes = Self.parseRoutes(AWCore.getTunnelExcludedRoutes())

        let ipv4Settings = NEIPv4Settings(addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()] + includedRoutes.ipv4
        var excludedIPv4Routes = excludedRoutes.ipv4
        if hideVPNIcon {
            excludedIPv4Routes.append(NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"))
        }
        ipv4Settings.excludedRoutes = excludedIPv4Routes
        settings.ipv4Settings = ipv4Settings
        
        let advertiseIPv6ToApps = AWCore.getAdvertiseIPv6ToApps() && !hideVPNIcon
        if advertiseIPv6ToApps {
            let ipv6Settings = NEIPv6Settings(addresses: [TunnelConstants.tunnelAddressIPv6], networkPrefixLengths: [64])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()] + includedRoutes.ipv6
            ipv6Settings.excludedRoutes = excludedRoutes.ipv6
            settings.ipv6Settings = ipv6Settings
        }
        
        let plainDNSServers: [String]
        if advertiseIPv6ToApps {
            plainDNSServers = [tunnelAddressIPv4, TunnelConstants.tunnelAddressIPv6]
        } else {
            plainDNSServers = [tunnelAddressIPv4]
        }

        settings.dnsSettings = NEDNSSettings(servers: plainDNSServers)
        settings.mtu = 1500

        return settings
    }
    
    private static func parseRoutes(_ strings: [String]) -> (ipv4: [NEIPv4Route], ipv6: [NEIPv6Route]) {
        var ipv4Routes: [NEIPv4Route] = []
        var ipv6Routes: [NEIPv6Route] = []

        for string in strings {
            if string.contains(":") {
                if let route = parseIPv6Route(string) {
                    ipv6Routes.append(route)
                }
            } else if let route = parseIPv4Route(string) {
                ipv4Routes.append(route)
            }
        }

        return (ipv4: ipv4Routes, ipv6: ipv6Routes)
    }
    
    private static func parseIPv4Route(_ string: String) -> NEIPv4Route? {
        let parts = string.split(separator: "/", maxSplits: 1)
        guard let addressPart = parts.first else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, String(addressPart), &address) == 1 else { return nil }

        var prefixLength = 32
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...32).contains(parsed) else { return nil }
            prefixLength = parsed
        }

        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        let network = UInt32(bigEndian: address.s_addr) & mask
        return NEIPv4Route(destinationAddress: dottedQuad(network), subnetMask: dottedQuad(mask))
    }
    
    private static func parseIPv6Route(_ string: String) -> NEIPv6Route? {
        let parts = string.split(separator: "/", maxSplits: 1)
        guard let addressPart = parts.first else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(addressPart), &address) == 1 else { return nil }

        var prefixLength = 128
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...128).contains(parsed) else { return nil }
            prefixLength = parsed
        }

        withUnsafeMutableBytes(of: &address) { bytes in
            for byteIndex in bytes.indices {
                let bitPosition = byteIndex * 8
                if bitPosition >= prefixLength {
                    bytes[byteIndex] = 0
                } else if bitPosition + 8 > prefixLength {
                    bytes[byteIndex] &= ~UInt8(0) << (8 - (prefixLength - bitPosition))
                }
            }
        }

        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return NEIPv6Route(destinationAddress: String(nulTerminated: buffer), networkPrefixLength: NSNumber(value: prefixLength))
    }

    private static func dottedQuad(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
    
    private func reapplyTunnelSettings() async {
        let settings = buildTunnelSettings()
        do {
            try await setTunnelNetworkSettings(settings)
            logger.info("[VPN] Tunnel settings reapplied")
        } catch {
            guard !Task.isCancelled else { return }
            logger.report("[VPN] Failed to reapply tunnel settings", error: error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
#if os(iOS)
        ControlCenter.shared.reloadControls(ofKind: "com.maxorax.turn.Widget.VPNToggle")
#endif
        
        statsRecorder.stop()
        report(.idle)
        path.withLock { $0 = nil }
        memoryWatch.withLock { watch in
            watch?.cancel()
            watch = nil
        }
        
        let task = rootTask.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        task?.cancel()
        
        logTunnelStop(reason: reason)
        
        await tunnelStack.stop()
        await TurnCore.shared.deactivate()

        // Last thing, and deliberately blocking: everything above is sitting in
        // the journal's buffer, and the process may not outlive this call.
        TunnelStack.flushPendingLogs()
    }

    /// Publishes the stage and wakes the app, which redraws the chart from it.
    private func report(_ next: TunnelStage, path routed: TunnelPath? = nil) {
        let changed = stage.withLock { current -> Bool in
            guard current != next else { return false }
            current = next
            return true
        }
        if let routed { path.withLock { $0 = routed } }
        guard changed || routed != nil else { return }
        AWNotificationCenter.notifyTurnStateChanged()
    }

    // MARK: - TURN

    /// Brings the VK TURN relay up when the configuration asks for it and returns
    /// a copy pointed at the relay's local listener. The TLS/Reality server name
    /// lives in `outbound` and is untouched, so the handshake still runs
    /// end-to-end against the real server.
    ///
    /// A relay that fails to start degrades to a direct connection rather than to
    /// no connection at all — the log says which path was taken.
    private func prepared(_ configuration: ProxyConfiguration,
                          forceRelay: Bool = false) async -> ProxyConfiguration {
        let target = "\(configuration.serverAddress):\(configuration.serverPort)"
        logger.info("[TURN] Selected proxy \"\(configuration.name)\" → \(target), "
                    + "protocol=\(configuration.outboundProtocol.rawValue), "
                    + "relay=\(configuration.turn == nil ? "none" : "configured")")

        // Remembered un-redirected, so a later network change can re-decide from
        // the original rather than from an address already pointed at the relay.
        baseConfiguration.withLock { $0 = configuration }

        guard let turn = configuration.turn else {
            report(.route, path: .direct)
            logger.warning("[TURN] No relay for \"\(configuration.name)\" — connecting DIRECTLY to \(target). "
                           + "The subscription carries no turn entry for this server.")
            await TurnCore.shared.deactivate()
            return configuration
        }

        // `forceRelay` skips the decision rather than repeating it. A tunnel
        // already on the relay is not asking whether to start relaying; it is
        // being moved to another interface, and re-running the choice there
        // would answer "Wi-Fi, go direct" and take the relay down.
        // Evaluated apart from the guard: `await` cannot sit to the right of `||`.
        let relaying = forceRelay ? true : await shouldRelay(configuration)
        guard relaying else {
            report(.route, path: .direct)
            await TurnCore.shared.deactivate()
            return configuration
        }
        report(.route, path: .turn)

        // A link the user entered in Settings replaces the subscription's, so an
        // exhausted or expired call can be swapped without reissuing the
        // subscription.
        var relay = turn
        let ownLink = AWCore.getTurnVKLink()
        if !ownLink.isEmpty, ownLink != relay.link {
            relay.link = ownLink
            logger.info("[TURN] Using the VK call link from Settings"
                        + (turn.link.isEmpty ? "" : " instead of the subscription's"))
        }

        // The relay is useless without a call to borrow credentials from, and a
        // subscription may ship one without a link on purpose, expecting the user
        // to supply their own.
        guard !relay.link.isEmpty else {
            report(.route, path: .direct)
            logger.warning("[TURN] No VK call link — neither the subscription nor Settings has one. "
                           + "Connecting DIRECTLY to \(target). Add a link in Settings → VK TURN.")
            await TurnCore.shared.deactivate()
            return configuration
        }

        // Captcha handling is the user's choice, not the subscription's.
        relay.manualCaptcha = !AWCore.getTurnAutoCaptcha()
        relay.captchaSolver = AWCore.getTurnCaptchaSolver()
        logger.info("[TURN] Captcha: \(relay.manualCaptcha ? "manual only" : "automatic (\(relay.captchaSolver)) then manual")")

        // Stream count is the user's dial too: the subscription only suggests one.
        relay.streams = AWCore.getTurnStreams()
        // Bond off. It splits a single TCP connection across every lane, which is
        // the right trade for one big download and the wrong one for everything
        // else: the journal caught a speedtest opening 35 connections in three
        // seconds, each fanned across all twenty lanes — seven hundred smux
        // streams at once, and the process was killed a second later. Traffic
        // that opens its own parallel connections needs no help being parallel,
        // and without the fan-out each connection takes one lane instead of
        // twenty.
        relay.bond = false

        // One set of credentials for every lane, however many are asked for.
        // Each set is another guest joining the VK call, and VK meets a join with
        // a captcha — not only at startup, since credentials last nine minutes and
        // every set goes back for its own. At the default ten this is exactly the
        // layout Cascade LTE ships and has always run on; above ten the extra
        // lanes reuse these credentials instead of buying a second captcha, and
        // any that VK's allocation quota turns away simply never come up. The
        // count in Settings is what tells them apart.
        relay.streamsPerCred = relay.streams
        logger.info("[TURN] Streams: \(relay.streams), all on one set of credentials")

        report(.relay)

        do {
            let endpoint = try await TurnCore.shared.activate(relay)
            let redirected = configuration.withRedirectedServer(address: endpoint.host, port: endpoint.port)
            logger.info("[TURN] Dialling \(endpoint.host):\(endpoint.port) instead of \(target); "
                        + "TLS server name stays \(redirected.xraySecurityLayer.serverName(fallback: configuration.serverAddress))")
            return redirected
        } catch {
            report(.route, path: .direct)
            logger.report("[TURN] Relay unavailable — FALLING BACK to a direct connection to \(target)", error: error)
            return configuration
        }
    }

    /// Decides whether this connection is worth relaying.
    ///
    /// Relaying costs a VK call and a detour, so `auto` spends it only where the
    /// direct path is actually broken: Wi-Fi goes straight out, and anything else
    /// is probed first. An unknown interface is treated as worth probing — the
    /// path monitor has not necessarily reported in yet when the tunnel starts,
    /// and the probe is the more truthful signal anyway.
    private func shouldRelay(_ configuration: ProxyConfiguration) async -> Bool {
        switch AWCore.getTurnMode() {
        case .off:
            logger.info("[TURN] Relay turned off in Settings — connecting directly")
            return false

        case .always:
            logger.info("[TURN] Relay set to always in Settings")
            return true

        case .auto:
            let network = await tunnelStack.networkContext
            if network.isWiFi {
                let where_ = network.ssid.map { " (\($0))" } ?? ""
                logger.info("[TURN] On Wi-Fi\(where_) — connecting directly, no relay needed")
                return false
            }

            let interface = network.isCellular ? "cellular" : "an unidentified network"
            logger.info("[TURN] On \(interface) — probing the network before relaying")
            report(.probe)

            // What replaced `LatencyTester` here, and why: that probe dialled our
            // own server through a full Reality handshake, which cost the whole
            // ten-second budget every time the answer was "blocked" — and on this
            // network that is the answer. It also could not tell a blocked path
            // from a dead one. Three well-known hosts settle both in a second.
            switch await ReachabilityProbe.run() {
            case .open:
                logger.info("[TURN] Network is open — connecting directly, no relay needed")
                return false
            case .censored:
                logger.info("[TURN] Network is filtered — switching to the VK relay")
                return true
            case .offline:
                // Relay anyway. This was the other way round and it cost a
                // session: a phone that had just moved to cellular answered
                // nothing for the whole budget, was called offline, and went
                // direct — down a path the carrier blocks. When nothing answers
                // there is nothing for a direct connection to do either, so the
                // cheaper mistake is to try the relay: VK's servers may well be
                // reachable where the three canaries are not, and if the network
                // really is gone the relay simply fails to come up.
                logger.warning("[TURN] Nothing answered on \(interface) — trying the VK relay anyway")
                return true
            }
        }
    }

    // MARK: - App Messages

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let message: TunnelMessage
        do {
            message = try JSONDecoder().decode(TunnelMessage.self, from: messageData)
        } catch {
            logger.report("[IPC] App message decode failed", error: TurnError.tunnel(.ipcFailed(underlying: error)))
            return nil
        }

        switch message {
        case .setConfiguration(let configuration):
            // Switching servers on a live tunnel never re-enters `startTunnel`,
            // so the chart has to be driven from here too: back to the start,
            // through `prepared` as usual, and told when it is over. Without the
            // last line it sat on Route for good.
            report(.profile)
            await tunnelStack.switchConfiguration(await prepared(configuration))
            report(.connected)
            return nil

        case .testLatency(let configuration):
            let response = LatencyTestResponse(await LatencyTester.test(configuration))
            return encodeReply(response)

        case .fetchStats:
            return encodeReply(statsRecorder.snapshot())

        case .fetchLogs:
            return encodeReply(LogsResponse(logs: tunnelStack.fetchLogs()))

        case .fetchRequests:
            return encodeReply(RequestsResponse(requests: tunnelStack.requestLog.snapshot()))

        case .fetchTurnState:
            return encodeReply(TurnStateResponse(
                state: await TurnCore.shared.state,
                stage: stage.withLock { $0 },
                path: path.withLock { $0 }
            ))
        }
    }
    
    private func encodeReply(_ reply: some Encodable) -> Data? {
        do {
            return try JSONEncoder().encode(reply)
        } catch {
            logger.report("[IPC] Reply encode failed", error: TurnError.tunnel(.ipcFailed(underlying: error)))
            return nil
        }
    }
    
    /// How often the footprint is written to the journal.
    ///
    /// Slow on purpose: this is a trajectory, not a profiler, and every line
    /// costs memory in the process it is measuring.
    private static let memoryWatchInterval = Duration.seconds(5)

    /// Narrates the process footprint and the relay's lane count on a slow tick.
    ///
    /// An extension killed for memory leaves no note — `stopTunnel` never runs,
    /// so the journal simply stops mid-sentence, which is exactly what the last
    /// speedtest produced. A footprint every few seconds turns that silence into
    /// evidence: the final line before the gap says how close the process was to
    /// the 50 MB an extension gets.
    /// How far apart two readings must be before the later one is worth a line.
    ///
    /// The watch samples every five seconds and used to write all of it down:
    /// twelve lines a minute, seventeen thousand a day, almost all of them
    /// identical to the line above. That is most of what the journal contains
    /// and nearly all of what a reader has to skip past — and it is what made a
    /// ceiling on total lines reachable in a night. A sample that says the same
    /// thing as the last one it reported says nothing.
    private static let footprintStep: UInt64 = 3          // MB
    private static let trafficStep: Int64 = 1024 * 1024   // bytes
    /// Reported regardless, so a quiet tunnel still proves it was alive.
    private static let heartbeat = Duration.seconds(300)

    private func startMemoryWatch() {
        let task = Task { [weak self] in
            var lastFootprint: UInt64 = 0
            var lastLanes = ""
            var lastBytes: Int64 = 0
            var lastReport = ContinuousClock.now

            while !Task.isCancelled {
                guard let self else { return }
                let footprint = Self.memoryFootprint()
                let relay = await TurnCore.shared.state
                let lanes = relay.activeStreams.map { "\($0)/\(relay.streams ?? 0)" } ?? "none"
                let counts = tunnelStack.byteCounts.withLock { $0 }
                let moved = counts.totalBytesIn + counts.totalBytesOut

                let mb = footprint / 1024 / 1024
                let due = ContinuousClock.now - lastReport >= Self.heartbeat
                let changed = lanes != lastLanes
                    || mb.absoluteDistance(to: lastFootprint / 1024 / 1024) >= Self.footprintStep
                    || abs(moved - lastBytes) >= Self.trafficStep

                if due || changed {
                    lastFootprint = footprint
                    lastLanes = lanes
                    lastBytes = moved
                    lastReport = ContinuousClock.now
                    // Bytes and open connections alongside the footprint: a
                    // journal that only records failures cannot tell "nothing
                    // worked" from "nothing was tried", and that is exactly the
                    // question a connection which looks up but carries nothing
                    // raises.
                    logger.info("[VPN] Footprint \(mb) MB, relay lanes \(lanes), "
                                + "tcp \(FlowGauge.tcpTable), udp \(FlowGauge.udpTable), "
                                + "up \(Self.formatBytes(counts.totalBytesOut)), down \(Self.formatBytes(counts.totalBytesIn))")
                }
                try? await Task.sleep(for: Self.memoryWatchInterval)
            }
        }
        memoryWatch.withLock { watch in
            watch?.cancel()
            watch = task
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    override func sleep() async {
        statsRecorder.noteSleep()
        await tunnelStack.suspendOutbound()
    }

    override func wake() {
        statsRecorder.noteWake()
        Task { await tunnelStack.handleWake() }
    }

    // MARK: - Provider task tree

    private func run() async {
        await withDiscardingTaskGroup { group in
            group.addTask { [reapplySignal = tunnelStack.reapplySettingsSignal] in
                for await _ in reapplySignal {
                    await self.reapplyTunnelSettings()
                }
            }
            group.addTask {
                for await path in self.pathMonitorBridge.paths() {
                    guard path.status == .satisfied else { continue }
                    await self.resolveAndUpdateNetworkContext(path)
                }
            }
        }
    }

    // MARK: - Path Monitoring

    /// Pins the relay's sockets to the physical interface behind this path.
    ///
    /// The gomobile header asks for this on every network change so the relay's
    /// own reconnects leave the device instead of looping into the utun this
    /// process serves.
    ///
    /// **Currently not called.** Turning it on and the streams-per-credential
    /// change landed the same afternoon, and the speedtest through the relay
    /// broke somewhere in that pair — so binding is parked to see how the relay
    /// behaves without it. Two things have to be settled before it comes back:
    /// the interface is picked by position in `availableInterfaces` rather than
    /// by the type the path reports, and `setBindInterface` only reaches sockets
    /// created after it, so re-binding mid-session splits the lanes across two
    /// interfaces. It must come back before `includeAllNetworks` is switched on:
    /// that setting forces the relay's own sockets into the tunnel they feed.
    private func bindRelay(to path: Network.NWPath) async {
        guard let name = Self.physicalInterfaceName(for: path) else { return }
        let changed = boundInterface.withLock { stored -> Bool in
            guard stored != name else { return false }
            stored = name
            return true
        }
        guard changed else { return }
        await TurnCore.shared.bind(toInterface: name)
    }

    /// The first real interface on the path. `.other` covers the tunnel's own
    /// utun, which is precisely what the relay must not be pinned to.
    private static func physicalInterfaceName(for path: Network.NWPath) -> String? {
        path.availableInterfaces.first { $0.type != .other && $0.type != .loopback }?.name
    }

    /// Classifies a path into the context the relay decision and the
    /// trusted-network policy both read.
    private func networkContext(for path: Network.NWPath) async -> NetworkContext {
        let primaryType = path.availableInterfaces.first?.type
        let isWiFi = primaryType == .wifi
        let isCellular = primaryType == .cellular
#if os(iOS)
        if isWiFi {
            return NetworkContext(isWiFi: true, isCellular: false, ssid: await pathMonitorBridge.currentWiFiSSID())
        }
#endif
        return NetworkContext(isWiFi: isWiFi, isCellular: isCellular, ssid: nil)
    }

    private func resolveAndUpdateNetworkContext(_ path: Network.NWPath) async {
        DNSResolver.shared.flush()

        let previous = await tunnelStack.networkContext
        let context = await networkContext(for: path)
        await tunnelStack.updateNetworkContext(
            isWiFi: context.isWiFi,
            isCellular: context.isCellular,
            ssid: context.ssid
        )
        await reevaluateRelay(previous: previous)
    }

    /// Re-runs the relay decision when the device moves between Wi-Fi and
    /// cellular. Walking out of Wi-Fi range is exactly the moment the direct path
    /// stops working, and the point of `auto` is to notice without being asked.
    private func reevaluateRelay(previous: NetworkContext) async {
        guard AWCore.getTurnMode() == .auto else { return }

        let current = await tunnelStack.networkContext
        guard current.isWiFi != previous.isWiFi || current.isCellular != previous.isCellular else { return }
        guard let base = baseConfiguration.withLock({ $0 }), base.turn != nil else { return }

        let where_ = current.isWiFi ? "Wi-Fi" : current.isCellular ? "cellular" : "an unidentified network"
        logger.info("[TURN] Network changed to \(where_) — re-deciding whether to relay")

        // Deliberately one-way: once traffic is on the relay it stays there until
        // the user reconnects. Deciding to leave is cheap, but undoing that
        // decision is not — coming back needs fresh VK credentials and very
        // likely a captcha, and until that finishes there is no working path at
        // all. Staying costs a detour; leaving costs the connection.
        let relaying = TurnCore.relaying.load(ordering: .relaxed)
        if relaying {
            // Staying is not enough on its own: the relay's sessions to VK were
            // opened on the interface that just went away, and the core does not
            // rebuild them. Its listener survives and accepts connections it can
            // no longer carry, which reads as a dead internet rather than a lost
            // one. So rebuild on the new interface, and never re-run the
            // direct/relay decision while doing it.
            logger.info("[TURN] Network moved while relaying — rebuilding the relay on the new interface")
            await TurnCore.shared.deactivate()
        }

        await tunnelStack.switchConfiguration(await prepared(base, forceRelay: relaying))
        // `prepared` walks the chart through Probe and Route on its way to a
        // verdict, which is right while something is coming up and wrong here:
        // the tunnel is already carrying traffic. Without this the chart parks on
        // Route while the connection is plainly up.
        report(.connected)
    }

    private func logTunnelStop(reason: NEProviderStopReason) {
        let message: String
        let level: TunnelLogLevel

        switch reason {
        case .userInitiated:
            message = "[VPN] Tunnel stopped by user"
            level = .info
        case .providerFailed:
            message = "[VPN] Tunnel stopped because the provider failed"
            level = .error
        case .noNetworkAvailable:
            message = "[VPN] Tunnel stopped because the network became unavailable"
            level = .warning
        case .unrecoverableNetworkChange:
            message = "[VPN] Tunnel stopped because the network path changed"
            level = .warning
        case .providerDisabled:
            message = "[VPN] Tunnel stopped because the provider was disabled"
            level = .warning
        case .authenticationCanceled:
            message = "[VPN] Tunnel stopped because authentication was canceled"
            level = .warning
        case .configurationFailed:
            message = "[VPN] Tunnel stopped because configuration failed"
            level = .error
        case .idleTimeout:
            message = "[VPN] Tunnel stopped after being idle"
            level = .warning
        case .configurationDisabled:
            message = "[VPN] Tunnel stopped because the configuration was disabled"
            level = .warning
        case .configurationRemoved:
            message = "[VPN] Tunnel stopped because the configuration was removed"
            level = .warning
        case .superceded:
            message = "[VPN] Tunnel stopped because another VPN took over"
            level = .warning
        case .userLogout:
            message = "[VPN] Tunnel stopped because the user logged out"
            level = .warning
        case .userSwitch:
            message = "[VPN] Tunnel stopped because the active user changed"
            level = .warning
        case .connectionFailed:
            message = "[VPN] Tunnel stopped because the VPN connection failed"
            level = .warning
        case .sleep:
            message = "[VPN] Tunnel stopped for device sleep"
            level = .warning
        case .appUpdate:
            message = "[VPN] Tunnel stopped for app update"
            level = .info
        case .internalError:
            message = "[VPN] Tunnel stopped because Network Extension hit an internal error"
            level = .error
        case .none:
            message = "[VPN] Tunnel stopped"
            level = .info
        @unknown default:
            message = "[VPN] Tunnel stopped for an unknown reason"
            level = .warning
        }

        switch level {
        case .info:
            logger.info(message)
        case .warning:
            logger.warning(message)
        case .error:
            logger.error(message)
        }
    }
}

private extension UInt64 {
    /// Distance in either direction, without the trap an unsigned subtraction
    /// springs when the later reading is the smaller one.
    func absoluteDistance(to other: UInt64) -> UInt64 {
        self > other ? self - other : other - self
    }
}
