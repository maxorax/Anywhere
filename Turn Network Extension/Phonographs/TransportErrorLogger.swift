//
//  TransportErrorLogger.swift
//  Turn
//
//  Created by NodePassProject on 4/18/26.
//

import Foundation

nonisolated enum TransportErrorLogger {

    // MARK: - Formatting
    
    static func conciseErrorDescription(_ error: Error) -> String {
        if let error = error as? TurnError { return error.conciseDescription }
        var message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let redundantPrefixes = [
            "Connection failed: ",
            "Send failed: ",
            "Receive failed: ",
            "DNS resolution failed: "
        ]

        for prefix in redundantPrefixes where message.hasPrefix(prefix) {
            message.removeFirst(prefix.count)
            break
        }

        return message
    }

    // MARK: - Terminal Failure Logging

    fileprivate static func logTerminal(
        operation: String,
        endpoint: String,
        error: Error,
        logger: TurnLogger,
        prefix: String,
        context: String? = nil
    ) {
        let errorDescription = conciseErrorDescription(error)
        let suffix = context.map { " [\($0)]" } ?? ""

        if case TurnError.proxy(.naive, _) = error {
            logger.debug("\(prefix) \(operation) error: \(endpoint): \(errorDescription)\(suffix)")
            return
        }
        
        switch (error as? TurnError)?.peerClose {
        case .cascade:
            logger.debug("\(prefix) \(operation) after peer close: \(endpoint): \(errorDescription)\(suffix)")
            return
        case .reset:
            logger.info("\(prefix) \(operation) failed: \(endpoint): \(errorDescription)\(suffix)")
            return
        case .none:
            break
        }

        let line = "\(prefix) \(operation) failed: \(endpoint): \(errorDescription)\(suffix)"
        switch TurnError.severity(of: error) {
        case .debug: logger.debug(line)
        case .info: logger.info(line)
        case .warning: logger.warning(line)
        case .error: logger.error(line)
        }
    }

    // MARK: - Transient Failure Logging

    static func logTransientSend(
        endpoint: String,
        error: Error,
        logger: TurnLogger,
        prefix: String
    ) {
        let errorDescription = conciseErrorDescription(error)
        logger.warning("\(prefix) Send failed: \(endpoint): \(errorDescription)")
    }
}

// MARK: - ConnectionFailureReporter

nonisolated final class ConnectionFailureReporter {
    private let prefix: String
    private let logger: TurnLogger
    private var reported = false

    init(prefix: String, logger: TurnLogger) {
        self.prefix = prefix
        self.logger = logger
    }
    
    func report(operation: String, endpoint: @autoclosure () -> String, error: Error,
                context: @autoclosure () -> String? = nil) {
        guard !reported else { return }
        reported = true
        TransportErrorLogger.logTerminal(
            operation: operation,
            endpoint: endpoint(),
            error: error,
            logger: logger,
            prefix: prefix,
            context: context()
        )
    }
    
    func markReported() {
        reported = true
    }
}
