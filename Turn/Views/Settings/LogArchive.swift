//
//  LogArchive.swift
//  Turn
//
//  Created by NodePassProject on 8/27/26.
//

import Foundation
import UIKit

/// Renders diagnostic logs as a plain-text file a user can send back, so a
/// support report arrives as text instead of a screenshot.
///
/// One entry per line — `<ISO 8601 timestamp> [LEVEL] message` — under a `#`
/// header carrying the app version, OS and hardware the log came from.
enum LogArchive {
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static var appName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MTurn"
        return name.replacingOccurrences(of: " ", with: "-")
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Hardware identifier — `iPhone17,1` and friends. More useful in a bug
    /// report than the marketing name, which the system does not expose.
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func fileName(at date: Date) -> String {
        "\(appName)-log-\(fileStampFormatter.string(from: date)).txt"
    }

    static func export(_ entries: [LogsModel.LogEntry], at date: Date) -> String {
        var lines: [String] = [
            "# \(appName) diagnostic log",
            "# App: \(appVersion)",
            "# System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "# Device: \(deviceModel)",
            "# Exported: \(stampFormatter.string(from: date))",
            "# Entries: \(entries.count)",
            "#",
        ]
        for entry in entries {
            lines.append("\(stampFormatter.string(from: entry.timestamp)) [\(entry.level.token)] \(entry.message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension LogsModel.LogLevel {
    var token: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}
