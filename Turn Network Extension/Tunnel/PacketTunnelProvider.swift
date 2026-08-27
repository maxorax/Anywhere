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

        // Seed the network context before the first relay decision. The path
        // monitor starts with `run()` below, and `updateNetworkContext` drops
        // anything that arrives before the stack is up — so without this,
        // `shouldRelay` would classify every cold start as an unidentified
        // network and probe the direct path even on Wi-Fi.
        //
        // Binding happens here, after the settings are applied, so the relay is
        // pinned to the physical interface with the utun already in existence —
        // the situation the gomobile header describes.
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
            await bindRelay(to: path)
        } else {
            logger.warning("[VPN] Path monitor did not report in time — deciding on an unidentified network")
        }

        let effective = await prepared(configuration)
        await tunnelStack.start(packetFlow: packetFlow, configuration: effective)
        
        rootTask.withLock { task in
            guard task == nil else { return }
            task = Task { await self.run() }
        }
        
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
        
        let task = rootTask.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        task?.cancel()
        
        logTunnelStop(reason: reason)
        
        await tunnelStack.stop()
        await TurnCore.shared.deactivate()
    }

    // MARK: - TURN

    /// Brings the VK TURN relay up when the configuration asks for it and returns
    /// a copy pointed at the relay's local listener. The TLS/Reality server name
    /// lives in `outbound` and is untouched, so the handshake still runs
    /// end-to-end against the real server.
    ///
    /// A relay that fails to start degrades to a direct connection rather than to
    /// no connection at all — the log says which path was taken.
    private func prepared(_ configuration: ProxyConfiguration) async -> ProxyConfiguration {
        let target = "\(configuration.serverAddress):\(configuration.serverPort)"
        logger.info("[TURN] Selected proxy \"\(configuration.name)\" → \(target), "
                    + "protocol=\(configuration.outboundProtocol.rawValue), "
                    + "relay=\(configuration.turn == nil ? "none" : "configured")")

        // Remembered un-redirected, so a later network change can re-decide from
        // the original rather than from an address already pointed at the relay.
        baseConfiguration.withLock { $0 = configuration }

        guard let turn = configuration.turn else {
            logger.warning("[TURN] No relay for \"\(configuration.name)\" — connecting DIRECTLY to \(target). "
                           + "The subscription carries no turn entry for this server.")
            await TurnCore.shared.deactivate()
            return configuration
        }

        guard await shouldRelay(configuration) else {
            await TurnCore.shared.deactivate()
            return configuration
        }

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
        // Derived, not a second dial: every set of credentials is its own trip to
        // VK and any trip can be met with a captcha, so pack as many streams as
        // the core is known to get from one set. Ten is the core's own default;
        // asking for more per set buys nothing if VK will not issue that many
        // channels for one allocation.
        relay.streamsPerCred = min(relay.streams, TurnConfiguration.streamsPerCredentialSet)
        logger.info("[TURN] Streams: \(relay.streams), \(relay.streamsPerCred) per credential set")

        do {
            let endpoint = try await TurnCore.shared.activate(relay)
            let redirected = configuration.withRedirectedServer(address: endpoint.host, port: endpoint.port)
            logger.info("[TURN] Dialling \(endpoint.host):\(endpoint.port) instead of \(target); "
                        + "TLS server name stays \(redirected.xraySecurityLayer.serverName(fallback: configuration.serverAddress))")
            return redirected
        } catch {
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
            logger.info("[TURN] On \(interface) — probing the direct path before relaying")

            // LatencyTester rebuilds the configuration from scratch and keeps no
            // relay, so this measures the direct path even for a relayed proxy.
            switch await LatencyTester.test(configuration) {
            case .success(let milliseconds):
                logger.info("[TURN] Direct path answered in \(milliseconds) ms — no relay needed")
                return false
            case .insecure:
                logger.info("[TURN] Direct path answered but failed verification — relaying")
                return true
            case .failed, .testing:
                logger.warning("[TURN] Direct path unreachable on \(interface) — switching to the VK relay")
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
            await tunnelStack.switchConfiguration(await prepared(configuration))
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
            return encodeReply(TurnStateResponse(state: await TurnCore.shared.state))
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
    /// process serves. Skipped so far, which held up only because the relay was
    /// never forced through the tunnel — `includeAllNetworks` turns that risk
    /// into a certainty.
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
        await bindRelay(to: path)
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
        await tunnelStack.switchConfiguration(await prepared(base))
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
