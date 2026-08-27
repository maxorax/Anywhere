//
//  ConnectionStageToast.swift
//  Turn
//
//  Created by NodePassProject on 8/27/26.
//

import SwiftUI

/// One step of bringing the tunnel up, as the user should read it.
///
/// Connecting through a VK relay is several seconds of work the app used to do
/// in silence — pulling credentials, sometimes stopping for a captcha. A stalled
/// power button looked identical to a broken one, so every stage gets narrated.
struct ConnectionStage: Equatable {
    enum Kind: Equatable {
        case progress
        case success
        case warning
        case failure
    }

    let kind: Kind
    let title: String
    var detail: String?
    let systemImage: String
    /// True while the relay is parked on a captcha — tapping opens it.
    var opensCaptcha = false

    /// Success is a passing note; anything needing attention stays put.
    var autoDismisses: Bool { kind == .success }

    /// Derives the stage from the tunnel's status and the relay's phase.
    ///
    /// Returns `nil` when there is nothing worth saying — idle, or plainly
    /// disconnected.
    static func current(vpn: VPNStatus, relay: TurnState) -> ConnectionStage? {
        switch vpn {
        case .invalid, .disconnected:
            return nil

        case .disconnecting:
            return ConnectionStage(
                kind: .progress,
                title: vpn.localizedText,
                systemImage: "power"
            )

        case .connecting, .reasserting:
            if let relayStage = relayStage(relay) { return relayStage }
            return ConnectionStage(
                kind: .progress,
                title: vpn.localizedText,
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            )

        case .connected:
            if let relayStage = relayStage(relay), relayStage.kind != .success { return relayStage }
            return ConnectionStage(
                kind: .success,
                title: vpn.localizedText,
                detail: relay.phase == .ready ? String(localized: "Traffic goes through the VK relay.") : nil,
                systemImage: "checkmark.circle.fill"
            )
        }
    }

    /// The relay's own narration. `nil` when it has nothing to add — either it
    /// is not in play at all, or it is done and the tunnel status says more.
    private static func relayStage(_ relay: TurnState) -> ConnectionStage? {
        switch relay.phase {
        case .idle, .stopped:
            return nil

        case .connecting:
            return ConnectionStage(
                kind: .progress,
                title: String(localized: "Connecting through VK"),
                detail: String(localized: "Fetching relay credentials."),
                systemImage: "phone.arrow.up.right.fill"
            )

        case .captcha:
            return ConnectionStage(
                kind: .warning,
                title: String(localized: "VK captcha required"),
                detail: String(localized: "Tap to solve it."),
                systemImage: "exclamationmark.triangle.fill",
                opensCaptcha: true
            )

        case .error:
            let reported = relay.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConnectionStage(
                kind: .failure,
                title: String(localized: "VK relay failed"),
                detail: reported?.isEmpty == false ? reported : String(localized: "Connecting directly instead."),
                systemImage: "xmark.circle.fill"
            )

        case .ready:
            return ConnectionStage(
                kind: .success,
                title: String(localized: "Relay ready"),
                systemImage: "checkmark.circle.fill"
            )
        }
    }
}

/// Drops the current stage in from the top of the screen.
struct ConnectionStageToast: View {
    let stage: ConnectionStage?
    var onTap: () -> Void

    /// Held separately from `stage` so a success can linger for a moment and
    /// then leave on its own, instead of vanishing the instant the phase moves.
    @State private var shown: ConnectionStage?

    private static let successLinger = Duration.seconds(2.5)

    var body: some View {
        VStack {
            if let shown {
                capsule(shown)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .animation(.snappy(duration: 0.3, extraBounce: 0), value: shown)
        .task(id: stage) {
            guard let stage else {
                shown = nil
                return
            }
            shown = stage
            guard stage.autoDismisses else { return }
            try? await Task.sleep(for: Self.successLinger)
            guard !Task.isCancelled else { return }
            shown = nil
        }
    }

    @ViewBuilder
    private func capsule(_ stage: ConnectionStage) -> some View {
        let content = HStack(spacing: 10) {
            icon(stage)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title)
                    .font(.subheadline.weight(.medium))
                if let detail = stage.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if stage.opensCaptcha {
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: 420)

        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
        }
        .contentShape(Capsule())
        .onTapGesture {
            guard stage.opensCaptcha else { return }
            onTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stage.opensCaptcha ? .isButton : [])
    }

    @ViewBuilder
    private func icon(_ stage: ConnectionStage) -> some View {
        switch stage.kind {
        case .progress:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: stage.systemImage).foregroundStyle(.green)
        case .warning:
            Image(systemName: stage.systemImage).foregroundStyle(.orange)
        case .failure:
            Image(systemName: stage.systemImage).foregroundStyle(.red)
        }
    }
}
