//
//  LogArchiveTests.swift
//  Turn Tests
//
//  Created by NodePassProject on 8/27/26.
//

import Foundation
import Testing

@testable import Turn

@MainActor
@Suite("LogArchive")
struct LogArchiveTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(
        _ offset: TimeInterval,
        _ level: LogsModel.LogLevel,
        _ message: String
    ) -> LogsModel.LogEntry {
        LogsModel.LogEntry(
            id: UUID(),
            timestamp: base.addingTimeInterval(offset),
            level: level,
            message: message
        )
    }

    @Test("Every entry reaches the exported file")
    func entriesAreExported() {
        let entries = [
            entry(0, .info, "[Tunnel] started"),
            entry(1.25, .warning, "[DNS] retrying upstream"),
            entry(2.5, .error, "[TCP] connect failed"),
        ]

        let text = LogArchive.export(entries, at: base)

        for entry in entries {
            #expect(text.contains(entry.message))
            #expect(text.contains("[\(entry.level.token)] \(entry.message)"))
        }
        #expect(text.hasSuffix("\n"))
    }

    @Test("The header carries the entry count and stands apart from the entries")
    func headerIsPresent() {
        let text = LogArchive.export([entry(0, .info, "only one")], at: base)
        let header = text.split(separator: "\n").prefix { $0.hasPrefix("#") }

        #expect(text.hasPrefix("#"))
        #expect(header.contains { $0.contains("Entries: 1") })
        #expect(header.contains { $0.hasPrefix("# App:") })
        #expect(header.contains { $0.hasPrefix("# Device:") })
    }

    @Test("The file name is stamped and safe to send as-is")
    func fileNameIsStamped() {
        let name = LogArchive.fileName(at: base)

        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains(" "))
        #expect(name.contains("-log-"))
    }
}
