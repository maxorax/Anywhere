//
//  StackHeadroom.swift
//  Turn
//

import Foundation
import Synchronization
import os.log

/// How much stack the current thread has left, and where it ran lowest.
///
/// Every crash report the extension has left — 27 of them — is a thread that ran
/// out of its 544 KB stack, and every one shows only the top 25–43 frames: a few
/// kilobytes. The rest is spent below a point the unwinder cannot cross
/// (`completeTaskWithClosure` on the lwIP queue, `runtime.asmcgocall` on the Go
/// core's threads), so the reports name the line that finished the stack off,
/// never what emptied it. These readings answer the question the reports can't:
/// is the stack already nearly gone when our code is entered, or does our code
/// spend it?
nonisolated enum StackHeadroom {
    enum Site: Int, CaseIterable {
        /// A line arriving from the Go core, on one of Go's own threads.
        case coreLog
        /// A job starting on a `BridgeExecutor` queue — lwIP above all.
        case executor
        /// A line entering the journal's buffer, on whatever thread logged it.
        case logSink

        var label: String {
            switch self {
            case .coreLog: "core-log"
            case .executor: "executor"
            case .logSink: "log-sink"
            }
        }
    }

    /// Below this, the site's stack is recorded once in the system log.
    static let warningThreshold = 64 * 1024

    private final class Slot: Sendable {
        let lowest = Atomic<Int>(Int.max)
        let reported = Atomic<Bool>(false)
    }

    private static let slots: [Slot] = Site.allCases.map { _ in Slot() }
    private static let osLogger = Logger(subsystem: "com.maxorax.turn", category: "StackHeadroom")

    /// Bytes between this call's frame and the bottom of the thread's stack.
    @inline(never)
    static func bytes() -> Int {
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        guard top > size, here > top - size, here <= top else { return 0 }
        return Int(here - (top - size))
    }

    /// Records a reading at `site`. Cheap enough for every log line and every
    /// executor job: two pthread calls and an atomic.
    ///
    /// The first time a site drops below `warningThreshold`, the raw return
    /// addresses go to os_log directly — not through the journal, whose path is
    /// exactly what fails at this depth, and not symbolicated, which would cost
    /// more stack than is left. The dylib's load address comes with them, so
    /// `atos -l` turns them into names afterwards.
    @inline(never)
    static func check(_ site: Site) {
        let left = bytes()
        let slot = slots[site.rawValue]
        var seen = slot.lowest.load(ordering: .relaxed)
        while left < seen {
            let (exchanged, original) = slot.lowest.compareExchange(expected: seen, desired: left, ordering: .relaxed)
            if exchanged { break }
            seen = original
        }
        guard left < warningThreshold else { return }
        guard slot.reported.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        var info = Dl_info()
        let base = dladdr(#dsohandle, &info) != 0 ? UInt(bitPattern: info.dli_fbase) : 0
        let frames = Thread.callStackReturnAddresses.prefix(96)
            .map { String($0.uintValue, radix: 16) }
            .joined(separator: " ")
        osLogger.fault("""
            stack low at \(site.label, privacy: .public): \(left, privacy: .public) bytes left; \
            image base 0x\(String(base, radix: 16), privacy: .public); frames \(frames, privacy: .public)
            """)
    }

    /// The lowest reading per site so far, in KB, for the journal's footprint
    /// line — e.g. "core-log 480K, executor 501K, log-sink 470K". Sites never
    /// reached are left out.
    static func summary() -> String {
        Site.allCases.compactMap { site in
            let value = slots[site.rawValue].lowest.load(ordering: .relaxed)
            return value == Int.max ? nil : "\(site.label) \(value / 1024)K"
        }.joined(separator: ", ")
    }
}
