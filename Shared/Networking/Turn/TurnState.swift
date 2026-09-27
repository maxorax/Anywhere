//
//  TurnState.swift
//  Turn
//

import Foundation

/// What the VK TURN relay is doing, as reported by `vkturn.State` in the Go core.
///
/// Lives in `Shared` rather than beside `TurnCore` because the app needs it too:
/// the core runs inside the tunnel process, which cannot present a captcha, so
/// the app asks for this over IPC and puts a WebView on screen.
nonisolated struct TurnState: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle, connecting, captcha, ready, stopped, error
    }

    var phase: Phase
    var running: Bool
    var listenAddr: String?
    var captchaUrl: String?
    var error: String?
    /// Lanes the relay was asked for.
    var streams: Int?
    /// Lanes actually carrying traffic right now.
    ///
    /// Neither figure comes from `vkturn.State` — the bridge does not report
    /// them. The extension fills both in: the ask is its own configuration, and
    /// the live count is read out of the core's `(active: N)` log lines, the
    /// only place the session pool is published. `nil` means the core has not
    /// said anything about its lanes yet.
    var activeStreams: Int?
    /// Captchas VK accepted since the core started, and how the latest was
    /// passed — "auto" or "manual". An automatic solve never enters the
    /// `captcha` phase, so this is the only trace of it.
    var captchasSolved: Int?
    var lastCaptcha: String?

    static let idle = TurnState(phase: .idle, running: false)

    /// Where the core raised its captcha page, once it has asked for one.
    var captchaURL: URL? {
        guard phase == .captcha else { return nil }
        return URL(string: captchaUrl ?? "http://127.0.0.1:8765")
    }

    /// Everything the core reports, for the journal.
    var summary: String {
        var parts = ["phase=\(phase.rawValue)", "running=\(running)"]
        if let activeStreams { parts.append("lanes=\(activeStreams)/\(streams.map(String.init) ?? "?")") }
        if let listenAddr { parts.append("listen=\(listenAddr)") }
        if let captchaUrl { parts.append("captcha=\(captchaUrl)") }
        if let error, !error.isEmpty { parts.append("error=\(error)") }
        return parts.joined(separator: " ")
    }
}
