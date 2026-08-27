//
//  TurnCaptchaModel.swift
//  Turn
//

import Foundation
import NetworkExtension
import Observation
import UserNotifications

/// Watches the VK TURN relay for a captcha prompt and hands the app a URL to
/// show.
///
/// The relay runs inside the tunnel process, which cannot present UI. It raises
/// a local web page instead and announces the phase change over a Darwin
/// notification; the app answers by fetching state over IPC and putting a
/// WebView on that page. The core collects the solved token from its own server,
/// so nothing has to travel back.
@MainActor
@Observable
final class TurnCaptchaModel {
    static let shared = TurnCaptchaModel()

    /// Non-nil while the core is waiting on a captcha.
    private(set) var captchaURL: URL?
    private(set) var lastState: TurnState = .idle

    /// Backstop for a missed notification — the app may have been suspended when
    /// the relay changed phase.
    private static let pollInterval = Duration.seconds(3)

    private var watcher: Task<Void, Never>?

    /// Set once the user closes the sheet, cleared only when the relay leaves
    /// the captcha cycle for good. A rejected captcha sends the core back
    /// through `connecting`/`error` and into `captcha` again within seconds, so
    /// without this the sheet reappears right after every Close and there is no
    /// way back to the app to stop the tunnel.
    private var suppressed = false

    private init() {}

    func start() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            await self?.requestNotificationPermission()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.observeNotifications() }
                group.addTask { await self?.poll() }
            }
        }
    }

    /// The extension posts a local notification when VK asks for a captcha —
    /// which routinely happens while the app is in the background, since that is
    /// when the relay comes up. Asking here rather than at first launch means the
    /// prompt arrives with some context behind it.
    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        captchaURL = nil
        suppressed = false
        lastState = .idle
    }

    /// Closes the sheet without touching the relay. The core keeps waiting, but
    /// the sheet stays away until the relay reaches `ready` or is stopped —
    /// otherwise a flapping captcha would put it straight back on screen.
    func dismiss() {
        suppressed = true
        captchaURL = nil
    }

    /// Brings a dismissed captcha back — the connection toast is the way in, so
    /// closing the sheet is not a one-way door.
    func present() {
        guard lastState.phase == .captcha else { return }
        suppressed = false
        captchaURL = lastState.captchaURL
    }

    // MARK: - Private

    private func observeNotifications() async {
        let names = [AWNotificationCenter.Notification.turnStateChanged]
        for await _ in DarwinNotificationConcurrencyBridge.names(names) {
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func refresh() async {
        guard let session = await resolveSession() else {
            captchaURL = nil
            suppressed = false
            return
        }
        guard let data = try? JSONEncoder().encode(TunnelMessage.fetchTurnState),
              let response = await ProviderMessageConcurrencyBridge.send(data, over: session),
              let payload = try? JSONDecoder().decode(TurnStateResponse.self, from: response)
        else { return }

        lastState = payload.state
        apply(payload.state)
    }

    /// Decides what the sheet should be doing for a reported phase.
    ///
    /// The relay flaps under a rejected captcha: VK answers with an error, the
    /// core retries, and the phase cycles `captcha → connecting/error → captcha`
    /// in seconds. Tearing the sheet down on every departure from `captcha` is
    /// what made it blink open and closed, so the transient phases deliberately
    /// leave whatever is on screen alone.
    private func apply(_ state: TurnState) {
        switch state.phase {
        case .ready, .stopped, .idle:
            // The relay is done with captchas — take the sheet away and let a
            // future prompt through again.
            captchaURL = nil
            suppressed = false
        case .captcha:
            guard !suppressed else { return }
            captchaURL = state.captchaURL
        case .connecting, .error:
            break
        }
    }

    private func resolveSession() async -> NETunnelProviderSession? {
        let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
        guard let connection = managers?.first?.connection as? NETunnelProviderSession,
              connection.status == .connected || connection.status == .connecting else { return nil }
        return connection
    }
}
