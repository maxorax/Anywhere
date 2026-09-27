//
//  VPNViewModel.swift
//  Turn
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import NetworkExtension
import SwiftUI
import Observation

nonisolated private let logger = TurnLogger(category: "VPNViewModel")

@MainActor
@Observable
class VPNViewModel {
    static let shared = VPNViewModel()

    var vpnStatus: NEVPNStatus = .disconnected

    /// When the tunnel came up, as the system recorded it.
    ///
    /// Taken from `NEVPNConnection.connectedDate` rather than stamped in the app:
    /// the tunnel outlives the app, so a locally started clock would restart at
    /// zero every time the user comes back to a connection that never dropped.
    private(set) var connectedSince: Date?
    var selectedConfiguration: ProxyConfiguration? {
        didSet {
            if !_suppressSelectionPersistence {
                selectedChainId = nil
                AWCore.setSelectedChainId(nil)
                AWCore.setSelectedConfigurationId(selectedConfiguration?.id)
                RoutingRuleSetStore.shared.scheduleSyncToAppGroup()
            }
            if vpnStatus == .connected, let selectedConfiguration {
                sendConfigurationToTunnel(selectedConfiguration)
            }
        }
    }
    private(set) var selectedChainId: UUID?
    var latencyResults: [UUID: LatencyResult] = [:]
    var chainLatencyResults: [UUID: LatencyResult] = [:]
    var startError: String?

    private(set) var isManagerReady = false
    @ObservationIgnored private var vpnManager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: Task<Void, Never>?
    private(set) var pendingReconnect = false
    /// Whether the running session was started by holding the power button, so
    /// a reconnect after a settings change stays on the relay.
    private(set) var relayForced = false
    /// Debounces a transient `.reasserting` (network blip) while connected so the UI keeps
    /// showing "Connected" unless the reconnect persists past ``reassertingDebounceInterval``.
    @ObservationIgnored private var reassertingDebounceTask: Task<Void, Never>?
    private static let reassertingDebounceInterval: Duration = .seconds(5)
    /// Set only via `withoutSelectionPersistence` so the flag always resets.
    @ObservationIgnored private var _suppressSelectionPersistence = false

    /// Assigns `selectedConfiguration` without triggering the chain-clearing didSet branch.
    private func withoutSelectionPersistence(_ block: () -> Void) {
        _suppressSelectionPersistence = true
        defer { _suppressSelectionPersistence = false }
        block()
    }

    init() {
        restoreLatencyResults()
        setupStatusObserver()
        setupVPNManager()
    }

    // MARK: - Selection

    private func restoreSelection(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        guard selectedConfiguration == nil, selectedChainId == nil else { return }
        if let savedChainId = AWCore.getSelectedChainId(),
           let chain = chains.first(where: { $0.id == savedChainId }),
           let resolved = chain.resolveComposite(from: configurations) {
            selectedChainId = savedChainId
            withoutSelectionPersistence { selectedConfiguration = resolved }
        } else if let savedConfigurationId = AWCore.getSelectedConfigurationId(),
                  let configuration = configurations.first(where: { $0.id == savedConfigurationId }) {
            withoutSelectionPersistence { selectedConfiguration = configuration }
        } else {
            selectedConfiguration = configurations.first
        }
    }

    func revalidateSelection(configurations: [ProxyConfiguration], chains: [ProxyChain]) {
        if selectedConfiguration == nil, selectedChainId == nil {
            restoreSelection(configurations: configurations, chains: chains)
            return
        }
        if let chainId = selectedChainId {
            if let chain = chains.first(where: { $0.id == chainId }),
               let resolved = chain.resolveComposite(from: configurations) {
                withoutSelectionPersistence { selectedConfiguration = resolved }
            } else {
                selectedChainId = nil
                AWCore.setSelectedChainId(nil)
                selectedConfiguration = configurations.first
            }
        } else {
            if let selected = selectedConfiguration {
                if let refreshed = configurations.first(where: { $0.id == selected.id }) {
                    if refreshed != selected { selectedConfiguration = refreshed }
                } else {
                    selectedConfiguration = configurations.first
                }
            }
            if selectedConfiguration == nil {
                selectedConfiguration = configurations.first
            }
        }
    }

    func selectIfNone(_ configuration: ProxyConfiguration) {
        if selectedConfiguration == nil { selectedConfiguration = configuration }
    }

    // MARK: - Computed Properties

    var statusColor: Color {
        switch vpnStatus {
        case .connected:
            return .green
        case .connecting, .reasserting:
            return .yellow
        case .disconnecting:
            return .orange
        case .disconnected, .invalid:
            return .red
        @unknown default:
            return .gray
        }
    }
    
    var status: VPNStatus {
        VPNStatus(vpnStatus)
    }

    var statusText: String {
        status.localizedText
    }

    /// Only `.disconnecting` disables the button: every other transition has a
    /// meaningful tap behind it, and locking the control mid-connect left users
    /// with no way to abandon an attempt that had stalled.
    func isButtonDisabled(hasConfigurations: Bool) -> Bool {
        !isManagerReady || !hasConfigurations || vpnStatus == .disconnecting
    }

    // MARK: - Chain Selection

    func selectChain(_ chain: ProxyChain, configurations: [ProxyConfiguration]) {
        guard let resolved = chain.resolveComposite(from: configurations) else { return }
        selectedChainId = chain.id
        AWCore.setSelectedChainId(chain.id)
        AWCore.setSelectedConfigurationId(nil)
        RoutingRuleSetStore.shared.scheduleSyncToAppGroup()
        withoutSelectionPersistence { selectedConfiguration = resolved }
    }

    // MARK: - Latency Testing

    @ObservationIgnored private var latencyTask: Task<Void, Never>?
    /// Configurations marked `.testing` by the current run and not yet answered.
    @ObservationIgnored private var latencyPending: Set<UUID> = []

    nonisolated private static let maxConcurrentLatencyTests = 8

    /// Cancels the run in flight and puts back what its unanswered rows showed
    /// before. A cancelled run records nothing, so without this every row it had
    /// not reached stayed `.testing` — a spinner for as long as the app was open.
    /// Tapping one server during a "test all" was enough.
    private func cancelLatencyRun() {
        latencyTask?.cancel()
        latencyTask = nil
        for id in latencyPending where latencyResults[id] == .testing {
            latencyResults[id] = storedLatencyResults[id]
        }
        latencyPending.removeAll()
    }

    func testLatency(for configuration: ProxyConfiguration) {
        cancelLatencyRun()
        let configurationId = configuration.id
        latencyPending = [configurationId]
        latencyResults[configurationId] = .testing
        let useIPC = vpnStatus == .connected
        latencyTask = Task { [weak self] in
            let result = await Self.runSingleLatencyTest(for: configuration, viaIPC: useIPC, session: useIPC ? self?.providerSession : nil)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.recordLatencyResult(result, for: configurationId)
            }
        }
    }

    func testLatencies(for targets: [ProxyConfiguration]) {
        cancelLatencyRun()
        for config in targets {
            latencyResults[config.id] = .testing
        }
        latencyPending = Set(targets.map(\.id))
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        latencyTask = Task { [weak self] in
            await Self.runLatencyTests(targets, viaIPC: useIPC, session: session) { id, result in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.recordLatencyResult(result, for: id)
                }
            }
        }
    }

    // MARK: - Chain Latency Testing

    @ObservationIgnored private var chainLatencyTask: Task<Void, Never>?
    @ObservationIgnored private var chainLatencyPending: Set<UUID> = []

    /// Same as `cancelLatencyRun`, for chains.
    private func cancelChainLatencyRun() {
        chainLatencyTask?.cancel()
        chainLatencyTask = nil
        for id in chainLatencyPending where chainLatencyResults[id] == .testing {
            chainLatencyResults[id] = storedChainLatencyResults[id]
        }
        chainLatencyPending.removeAll()
    }

    func testChainLatency(for chain: ProxyChain, configurations: [ProxyConfiguration]) {
        guard let resolved = chain.resolveComposite(from: configurations) else { return }
        cancelChainLatencyRun()
        chainLatencyResults[chain.id] = .testing
        chainLatencyPending = [chain.id]
        let chainId = chain.id
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        chainLatencyTask = Task { [weak self] in
            let result = await Self.runSingleLatencyTest(for: resolved, viaIPC: useIPC, session: session)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.recordChainLatencyResult(result, for: chainId)
            }
        }
    }

    func testAllChainLatencies(chains: [ProxyChain], configurations: [ProxyConfiguration]) {
        cancelChainLatencyRun()
        var chainData: [(UUID, ProxyConfiguration)] = []
        for chain in chains {
            if let resolved = chain.resolveComposite(from: configurations) {
                chainLatencyResults[chain.id] = .testing
                chainLatencyPending.insert(chain.id)
                chainData.append((chain.id, resolved))
            }
        }
        let chainIdByConfigId: [UUID: UUID] = Dictionary(uniqueKeysWithValues: chainData.map { ($0.1.id, $0.0) })
        let useIPC = vpnStatus == .connected
        let session = useIPC ? providerSession : nil
        chainLatencyTask = Task { [weak self] in
            await Self.runLatencyTests(chainData.map(\.1), viaIPC: useIPC, session: session) { configId, result in
                if let chainId = chainIdByConfigId[configId] {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self?.recordChainLatencyResult(result, for: chainId)
                    }
                }
            }
        }
    }

    // MARK: - Latency Persistence
    
    @ObservationIgnored private var storedLatencyResults: [UUID: LatencyResult] = [:]
    @ObservationIgnored private var storedChainLatencyResults: [UUID: LatencyResult] = [:]

    private func restoreLatencyResults() {
        storedLatencyResults = Self.decodeLatencyResults(AWCore.getLatencyResultsData())
        storedChainLatencyResults = Self.decodeLatencyResults(AWCore.getChainLatencyResultsData())
        latencyResults = storedLatencyResults
        chainLatencyResults = storedChainLatencyResults
    }

    private func recordLatencyResult(_ result: LatencyResult, for configurationId: UUID) {
        latencyPending.remove(configurationId)
        latencyResults[configurationId] = result
        storedLatencyResults[configurationId] = result
        if let data = Self.encodeLatencyResults(storedLatencyResults) {
            AWCore.setLatencyResultsData(data)
        }
    }

    private func recordChainLatencyResult(_ result: LatencyResult, for chainId: UUID) {
        chainLatencyPending.remove(chainId)
        chainLatencyResults[chainId] = result
        storedChainLatencyResults[chainId] = result
        if let data = Self.encodeLatencyResults(storedChainLatencyResults) {
            AWCore.setChainLatencyResultsData(data)
        }
    }
    
    private static func encodeLatencyResults(_ results: [UUID: LatencyResult]) -> Data? {
        try? JSONEncoder().encode(results.mapValues { LatencyTestResponse($0) })
    }

    private static func decodeLatencyResults(_ data: Data?) -> [UUID: LatencyResult] {
        guard let data,
              let responses = try? JSONDecoder().decode([UUID: LatencyTestResponse].self, from: data) else {
            return [:]
        }
        return responses.mapValues { $0.asLatencyResult }
    }

    // MARK: - Latency Test Execution

    private var providerSession: NETunnelProviderSession? {
        vpnManager?.connection as? NETunnelProviderSession
    }

    nonisolated private static func runSingleLatencyTest(
        for configuration: ProxyConfiguration,
        viaIPC: Bool,
        session: NETunnelProviderSession?
    ) async -> LatencyResult {
        if viaIPC, let session {
            return await sendLatencyTestMessage(for: configuration, session: session)
        }
        return await LatencyTester.test(configuration)
    }

    /// Runs a batch of tests with at most `maxConcurrentLatencyTests` in flight, reporting each result as it arrives.
    nonisolated private static func runLatencyTests(
        _ configurations: [ProxyConfiguration],
        viaIPC: Bool,
        session: NETunnelProviderSession?,
        onResult: @Sendable @escaping (UUID, LatencyResult) async -> Void
    ) async {
        guard !configurations.isEmpty else { return }
        await withTaskGroup(of: (UUID, LatencyResult).self) { group in
            var iterator = configurations.makeIterator()
            for _ in 0..<min(Self.maxConcurrentLatencyTests, configurations.count) {
                if let config = iterator.next() {
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, viaIPC: viaIPC, session: session)
                        return (config.id, r)
                    }
                }
            }
            for await pair in group {
                await onResult(pair.0, pair.1)
                if let config = iterator.next() {
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, viaIPC: viaIPC, session: session)
                        return (config.id, r)
                    }
                }
            }
        }
    }

    /// Sends one `testLatency` IPC message and awaits the extension's reply. The extension
    /// resolves the address itself — main-app DNS while the tunnel is up yields lwIP fake IPs.
    nonisolated private static func sendLatencyTestMessage(
        for configuration: ProxyConfiguration,
        session: NETunnelProviderSession
    ) async -> LatencyResult {
        guard let messageData = try? JSONEncoder().encode(TunnelMessage.testLatency(configuration)) else { return .failed }

        let responseData = await ProviderMessageConcurrencyBridge.send(messageData, over: session)
        return (responseData.flatMap { try? JSONDecoder().decode(LatencyTestResponse.self, from: $0) })?.asLatencyResult ?? .failed
    }

    /// Returns `configuration` with `resolvedIP` set, preferring an existing value, then `fallback`,
    /// then a DNS lookup via the shared `DNSResolver` — on its blocking-resolve worker, so callers
    /// on the main actor or the cooperative pool never block on `getaddrinfo`.
    nonisolated static func withResolvedIP(
        _ configuration: ProxyConfiguration,
        fallback: String? = nil
    ) async -> ProxyConfiguration {
        if configuration.resolvedIP != nil { return configuration }
        let resolvedIP: String?
        if let fallback {
            resolvedIP = fallback
        } else {
            resolvedIP = await resolveServerAddress(configuration.serverAddress)
        }
        guard let resolved = resolvedIP else {
            return configuration
        }
        return ProxyConfiguration(
            id: configuration.id,
            name: configuration.name,
            serverAddress: configuration.serverAddress,
            serverPort: configuration.serverPort,
            resolvedIP: resolved,
            subscriptionId: configuration.subscriptionId,
            outbound: configuration.outbound,
            chain: configuration.chain,
            turn: configuration.turn
        )
    }

    // MARK: - Setup

    private func setupStatusObserver() {
        // The enclosing type is @MainActor, so this Task and `handleStatusChange` run on the
        // main actor.
        statusObserver = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
                guard !Task.isCancelled, let self else { return }
                guard let connection = note.object as? NEVPNConnection,
                      connection === self.vpnManager?.connection else { continue }
                self.handleStatusChange(connection.status, on: connection)
            }
        }
    }

    /// Routes a raw tunnel status to the UI, debouncing a transient reconnect.
    private func handleStatusChange(_ status: NEVPNStatus, on connection: NEVPNConnection) {
        reassertingDebounceTask?.cancel()
        reassertingDebounceTask = nil

        if status == .reasserting, vpnStatus == .connected {
            reassertingDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.reassertingDebounceInterval)
                guard !Task.isCancelled, let self else { return }
                // Re-check the live status: apply only if it never recovered.
                guard connection.status == .reasserting else { return }
                self.applyStatus(.reasserting, on: connection)
            }
            return
        }

        applyStatus(status, on: connection)
    }

    /// Applies a tunnel status to `vpnStatus` and drives the stats-polling side effects.
    private func applyStatus(_ status: NEVPNStatus, on connection: NEVPNConnection) {
        vpnStatus = status
        connectedSince = status == .connected ? connection.connectedDate : nil
        let stats = ConnectionStatsModel.shared
        if status == .connected {
            if let session = connection as? NETunnelProviderSession {
                stats.startPolling(session: session)
            }
        } else {
            stats.stopPolling()
            if status == .disconnected || status == .invalid {
                stats.reset()
                if pendingReconnect {
                    pendingReconnect = false
                    connectVPN(forceRelay: relayForced)
                }
            }
        }
    }

    private static let providerBundleIdentifier = "com.maxorax.turn.Network-Extension"

    private func setupVPNManager() {
        Task {
            let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
            if let manager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
            }) ?? managers?.first {
                self.vpnManager = manager
                self.vpnStatus = manager.connection.status
                self.connectedSince = manager.connection.status == .connected
                    ? manager.connection.connectedDate
                    : nil
                if manager.connection.status == .connected,
                   let session = manager.connection as? NETunnelProviderSession {
                    ConnectionStatsModel.shared.startPolling(session: session)
                }
            } else {
                self.vpnManager = NETunnelProviderManager()
            }
            self.isManagerReady = true
        }
    }

    // MARK: - Actions

    func toggleVPN() {
        switch vpnStatus {
        case .connected, .connecting, .reasserting:
            // Bringing a tunnel up can take minutes — a VK relay waiting on a
            // captcha is the worst of it — so the button has to be able to call
            // the attempt off, not just start one.
            disconnectVPN()
        case .disconnected, .invalid:
            connectVPN()
        default:
            break
        }
    }

    /// Long press on the power button: connect through the VK relay whatever
    /// `TurnMode` says. A tunnel that is already up or on its way is restarted
    /// on the relay rather than left on whatever path it chose.
    func forceRelayVPN() {
        switch vpnStatus {
        case .disconnected, .invalid:
            connectVPN(forceRelay: true)
        case .connected, .connecting:
            relayForced = true
            reconnectVPN()
        default:
            break
        }
    }

    func connectVPN(forceRelay: Bool = false) {
        guard let manager = vpnManager,
              let configuration = selectedConfiguration else { return }
        relayForced = forceRelay

        Task { [self] in
            // Resolves on DNSResolver's worker queue, off both the main actor and
            // the cooperative pool.
            let resolvedIP = await VPNViewModel.resolveServerAddress(configuration.serverAddress)

            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = "com.maxorax.turn.Network-Extension"
            tunnelProtocol.serverAddress = "Turn"
            #if !os(tvOS)
            tunnelProtocol.includeAllNetworks = AWCore.getTunnelIncludeAllNetworks()
            tunnelProtocol.excludeLocalNetworks = !AWCore.getTunnelIncludeLocalNetworks()
            tunnelProtocol.excludeAPNs = !AWCore.getTunnelIncludeAPNs()
            tunnelProtocol.excludeCellularServices = !AWCore.getTunnelIncludeCellularServices()
            #endif

            manager.protocolConfiguration = tunnelProtocol
            manager.localizedDescription = "Turn"
            manager.isEnabled = true

            let alwaysOn = AWCore.getAlwaysOnEnabled()
            if alwaysOn {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
            } else {
                manager.isOnDemandEnabled = false
                manager.onDemandRules = nil
            }

            do {
                try await manager.saveToPreferences()
                // Reload so the connection reference is valid after the save round-trip.
                try await manager.loadFromPreferences()

                let resolved = await Self.withResolvedIP(configuration, fallback: resolvedIP)

                // Persist to App Group so the NE can read it when started from Settings or On Demand, where options is nil.
                if let configData = try? JSONEncoder().encode(resolved) {
                    AWCore.setLastConfigurationData(configData)
                }

                let messageData = try JSONEncoder().encode(TunnelMessage.setConfiguration(resolved))
                var options: [String: NSObject] = [TunnelMessage.optionKey: messageData as NSObject]
                if forceRelay {
                    options[TunnelMessage.forceRelayOptionKey] = NSNumber(value: true)
                }
                try manager.connection.startVPNTunnel(options: options)
            } catch {
                self.startError = error.localizedDescription
            }
        }
    }

    func disconnectVPN() {
        guard let manager = vpnManager else { return }
        // Clear any pending reconnect — an explicit disconnect should not auto-reconnect
        pendingReconnect = false
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            Task {
                try? await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    func reconnectVPN() {
        guard let manager = vpnManager,
              vpnStatus == .connected || vpnStatus == .connecting else { return }
        pendingReconnect = true
        // Disable on-demand first to prevent system auto-restart during reconnection
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            Task {
                try? await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
        } else {
            manager.connection.stopVPNTunnel()
        }
    }

    // MARK: - Configuration Switching

    private func sendConfigurationToTunnel(_ configuration: ProxyConfiguration) {
        guard let session = vpnManager?.connection as? NETunnelProviderSession else { return }

        Task.detached {
            let resolved = await Self.withResolvedIP(configuration)

            // Keep App Group in sync so On Demand restarts use the latest selection.
            if let configData = try? JSONEncoder().encode(resolved) {
                AWCore.setLastConfigurationData(configData)
            }

            guard let data = try? JSONEncoder().encode(TunnelMessage.setConfiguration(resolved)) else { return }
            _ = await ProviderMessageConcurrencyBridge.send(data, over: session)
        }
    }

    // MARK: - DNS Resolution

    /// Resolves a server address to an IP string (IP literals pass through) via the
    /// shared `DNSResolver`, so proxy lookups share the transport layers' cache. The
    /// blocking lookup runs on the resolver's worker queue, not the caller's thread.
    nonisolated static func resolveServerAddress(_ address: String) async -> String? {
        await DNSResolver.shared.resolveHost(address)
    }

}

extension NEVPNStatus {
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}

extension VPNStatus {
    /// Unknown future tunnel states read as `.invalid`.
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }
}
