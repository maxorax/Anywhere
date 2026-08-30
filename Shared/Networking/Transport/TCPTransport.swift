//
//  TCPTransport.swift
//  Turn
//
//  Created by NodePassProject on 7/14/26.
//

import Foundation
import Network
import Synchronization

nonisolated private let logger = TurnLogger(category: "TCPTransport")

nonisolated protocol TCPTransportEngine: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive(atMost maxLength: Int) async throws -> (content: Data, endOfStream: Bool)
}

nonisolated final class TCPTransport: ByteTransport, Sendable {

    // MARK: Constants

    private static let connectTimeout: UInt32 = 16
    private static let maxReceiveLength = 65535

    // MARK: State

    private struct State {
        var engine: (any TCPTransportEngine)?
        var flowSlot: FlowSlot?
        var ready = false
        var cancelled = false
        var failure: TurnError?
        var eofLatched = false
        /// When the engine was handed the endpoint.
        var dialBegan: ContinuousClock.Instant?
        var firstWriteReported = false
    }

    private let state = Mutex(State())

    private let host: String
    private let port: UInt16
    private let resolvesViaProxyDNS: Bool
    let endpointDescription: String

    private let dialAttempt: ConnectionMetrics.Attempt?
    
    init(host: String, port: UInt16, resolvesViaProxyDNS: Bool = false) {
        self.host = host
        self.port = port
        self.resolvesViaProxyDNS = resolvesViaProxyDNS
        self.endpointDescription = "\(host):\(port)"
        self.dialAttempt = ConnectionMetrics.currentAttempt
    }

    deinit {
        cancel()
    }

    var isReady: Bool {
        state.withLock { $0.ready && !$0.cancelled && $0.failure == nil }
    }

    // MARK: - Connect

    func connect(initialData: Data? = nil) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TurnError.transport(.connectionFailed(endpoint: nil, detail: "invalid port \(port)"))
        }
        let endpointHost = await NWEndpoint.Host.dialHost(for: host, viaProxyDNS: resolvesViaProxyDNS)
        let endpoint = NWEndpoint.hostPort(host: endpointHost, port: nwPort)
        let slot = FlowSlot(context: "[TCP] \(endpointDescription)")
        
        let engine: any TCPTransportEngine
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            engine = ModernTCPEngine(endpoint: endpoint, connectTimeout: Self.connectTimeout)
        } else {
            engine = LegacyTCPEngine(endpoint: endpoint, connectTimeout: Self.connectTimeout)
        }

        let live: Bool = state.withLock { state in
            guard !state.cancelled else { return false }
            state.flowSlot = slot
            state.engine = engine
            state.dialBegan = ContinuousClock.now
            return true
        }
        guard live else {
            slot.release()
            throw TurnError.transport(.terminated)
        }

        if let initialData, !initialData.isEmpty {
            do {
                try await engine.send(initialData)
            } catch {
                cancel()
                throw latchedFailure() ?? TurnError.networkFailure(error, operation: .connect)
            }
            reportFirstWrite()
        }
        state.withLock { $0.ready = true }
    }

    /// How long the socket took to reach the far end, reported once.
    ///
    /// The modern engine dials lazily — `connect` only hands it the endpoint, and
    /// the TCP connect itself happens on the first write. So this is the only
    /// place that can time it, and the number matters: a dial to the VK relay's
    /// own listener on 127.0.0.1 that takes seconds is a different failure from
    /// one that connects instantly and then waits on the far side.
    private func reportFirstWrite() {
        let began: ContinuousClock.Instant? = state.withLock { state in
            guard !state.firstWriteReported, let began = state.dialBegan else { return nil }
            state.firstWriteReported = true
            return began
        }
        guard let began else { return }
        logger.info("[TCP] \(endpointDescription) took the first write after "
                    + "\((ContinuousClock.now - began).milliseconds)ms")
    }

    // MARK: - ByteTransport

    func send(_ data: Data) async throws {
        let engine = try activeEngine()
        do {
            try await engine.send(data)
        } catch {
            throw latchedFailure() ?? TurnError.networkFailure(error, operation: .send)
        }
        reportFirstWrite()
    }

    func receive() async throws -> TransportChunk {
        while true {
            if state.withLock({ $0.eofLatched }) { return .end }
            let engine = try activeEngine()

            let message: (content: Data, endOfStream: Bool)
            do {
                message = try await engine.receive(atMost: Self.maxReceiveLength)
            } catch {
                throw latchedFailure() ?? TurnError.networkFailure(error, operation: .receive)
            }

            if !message.content.isEmpty {
                dialAttempt?.noteServerResponse()
                if message.endOfStream { state.withLock { $0.eofLatched = true } }
                return .bytes(message.content)
            }
            if message.endOfStream {
                state.withLock { $0.eofLatched = true }
                return .end
            }
        }
    }

    func cancel() {
        // Engines tear down on release; in-flight operations end via task cancellation.
        let (_, slot): ((any TCPTransportEngine)?, FlowSlot?) = state.withLock { state in
            if state.failure == nil { state.failure = .transport(.terminated) }
            state.cancelled = true
            state.ready = false
            let pair = (state.engine, state.flowSlot)
            state.engine = nil
            state.flowSlot = nil
            return pair
        }
        slot?.release()
    }

    // MARK: - Helpers

    private func activeEngine() throws -> any TCPTransportEngine {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            if state.cancelled { throw TurnError.transport(.terminated) }
            guard let engine = state.engine else { throw TurnError.transport(.notConnected) }
            return engine
        }
    }

    private func latchedFailure() -> TurnError? {
        state.withLock { $0.failure }
    }
}

// MARK: - Modern engine

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
nonisolated final class ModernTCPEngine: TCPTransportEngine, Sendable {

    private let connection: NetworkConnection<TCP>

    init(endpoint: NWEndpoint, connectTimeout: UInt32) {
        connection = NetworkConnection(to: endpoint) {
            TCP()
                .noDelay(true)
                .keepalive(idleTimeInSeconds: 30, count: 3, intervalInSeconds: 10)
                .connectionTimeout(connectTimeout)
        }
    }

    func send(_ data: Data) async throws {
        try await connection.send(data, endOfStream: false)
    }

    func receive(atMost maxLength: Int) async throws -> (content: Data, endOfStream: Bool) {
        let message = try await connection.receive(atLeast: 1, atMost: maxLength)
        return (message.content, message.metadata.endOfStream)
    }
}

private extension Duration {
    nonisolated var milliseconds: Int {
        let components = self.components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
