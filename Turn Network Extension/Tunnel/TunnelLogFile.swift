//
//  TunnelLogFile.swift
//  Turn Network Extension
//

import Foundation
import Synchronization

/// Mirrors the journal into a file that outlives the tunnel process.
///
/// `TunnelStack` keeps its journal in memory and hands it to the app over IPC,
/// which is enough until the case worth reading: an extension that crashed or
/// was killed for memory takes its own account of what happened with it, and
/// the app is left with nothing to ask. This copy survives that, and survives
/// the app being force-quit too.
///
/// The file sits at `Library/turn.log` inside the App Group container on
/// purpose. `devicectl device copy from` reaches only `Library`, `Documents`
/// and `tmp` of a container, so from there it can be pulled off a device with
/// nothing but a cable and no root:
///
/// ```sh
/// xcrun devicectl device copy from --device <id> \
///     --domain-type appGroupDataContainer \
///     --domain-identifier group.com.maxorax.turn \
///     --source Library/turn.log --destination ./turn.log
/// ```
nonisolated final class TunnelLogFile: Sendable {
    static let shared = TunnelLogFile()

    /// Rotated once it passes this, with one generation kept — the pair cannot
    /// outgrow twice this inside a container the user can neither see nor tidy.
    private static let maximumBytes = 4 * 1024 * 1024

    /// Space instead of `T` and a real fractional part: these lines are read
    /// beside the core's own log, which stamps the same way.
    private static let stamp = Date.ISO8601FormatStyle(
        dateTimeSeparator: .space,
        includingFractionalSeconds: true,
        timeZone: .current
    )

    private struct Sink {
        var handle: FileHandle
        var bytes: Int
    }

    private let current: URL?
    private let rotated: URL?
    private let sink = Mutex<Sink?>(nil)

    private init() {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AWCore.Identifier.appGroupSuite)?
            .appendingPathComponent("Library", isDirectory: true)
        current = directory?.appendingPathComponent("turn.log")
        rotated = directory?.appendingPathComponent("turn.log.1")
    }

    func append(_ message: String, level: TunnelLogLevel) {
        let line = "\(Self.stamp.format(Date())) \(Self.tag(level)) \(message)\n"
        let data = Data(line.utf8)

        sink.withLock { sink in
            if sink == nil { sink = open() }
            guard var state = sink else { return }

            do {
                try state.handle.write(contentsOf: data)
            } catch {
                // A full disk or a revoked container: drop the handle and let
                // the next line try again rather than lose the tunnel over it.
                try? state.handle.close()
                sink = nil
                return
            }

            state.bytes += data.count
            guard state.bytes > Self.maximumBytes else {
                sink = state
                return
            }
            try? state.handle.close()
            rotate()
            sink = open()
        }
    }

    /// Opens the file for appending, announcing itself so the boundary between
    /// two tunnel processes is visible — which is the whole point of the file
    /// when the previous one was killed rather than stopped.
    private func open() -> Sink? {
        guard let current else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: current.path) {
            manager.createFile(atPath: current.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: current) else { return nil }

        let end = (try? handle.seekToEnd()) ?? 0
        let banner = Data("\(Self.stamp.format(Date())) INFO  --- tunnel process log opened ---\n".utf8)
        try? handle.write(contentsOf: banner)
        return Sink(handle: handle, bytes: Int(end) + banner.count)
    }

    private func rotate() {
        guard let current, let rotated else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: rotated)
        try? manager.moveItem(at: current, to: rotated)
    }

    private static func tag(_ level: TunnelLogLevel) -> String {
        switch level {
        case .info: "INFO "
        case .warning: "WARN "
        case .error: "ERROR"
        }
    }
}
