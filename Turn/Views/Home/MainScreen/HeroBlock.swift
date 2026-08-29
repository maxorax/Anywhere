//
//  HeroBlock.swift
//  Turn
//

import SwiftUI

/// The top half of the main screen: the button, the chart beside it, and the
/// one line that says what is going on.
///
/// The chart sits to the left rather than under the button on purpose — the
/// point of the redesign is that the path is readable at a glance, in the same
/// look as the button rather than in a separate panel below it.
struct HeroBlock: View {
    let flow: StageFlow
    let orbState: ConnectionOrb.State
    /// Emoji flag and name of the server the button would connect to.
    let serverFlag: String?
    let serverName: String?
    let connectedSince: Date?
    var onToggle: () -> Void
    var onCaptcha: () -> Void
    /// Tapping the running timer opens the connection statistics.
    var onStatus: () -> Void = {}

    private static let height: CGFloat = 210

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                StageFlowChart(flow: flow, onCaptcha: onCaptcha)
                    .offset(x: 8, y: 4)
                ConnectionOrb(state: orbState, action: onToggle)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
            .frame(height: Self.height)

            if let serverName {
                HStack(spacing: 6) {
                    if let serverFlag { Text(serverFlag).font(.system(size: 15)) }
                    Text(serverName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 340)
            }

            status
        }
    }

    /// The timer once traffic is flowing, an invitation before that. Amber for a
    /// session going through VK, so a relayed connection is legible from the
    /// caption alone.
    private var status: some View {
        Group {
            if orbState == .on, let connectedSince {
                // Wrapped in the same capsule as the header buttons, with a
                // chevron: a bare line of text gave no hint that the statistics
                // are behind it.
                Button(action: onStatus) {
                    HStack(spacing: 6) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.elapsed(since: connectedSince, now: context.date))
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.6)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(MainScreen.surface(0.07))
                            .overlay(Capsule().stroke(MainScreen.surface(0.09), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            } else if orbState == .connecting, flow.relay.phase == .captcha {
                // The captcha sheet can be closed without solving it, and until
                // it is solved nothing else happens. This is the way back in.
                Button(action: onCaptcha) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Solve the captcha")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(MainScreen.amber.opacity(0.14))
                            .overlay(Capsule().stroke(MainScreen.amber.opacity(0.5), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            } else {
                Text(orbState == .connecting
                     ? String(localized: "Connecting…")
                     : String(localized: "Tap to connect"))
            }
        }
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .kerning(0.4)
        .foregroundStyle(statusColour)
        .animation(MainScreen.statusFade, value: orbState)
    }

    /// Green when the traffic goes straight out, blue when it goes through VK.
    ///
    /// The handoff used amber for the relayed session, but amber is the colour
    /// this screen uses for "in progress, or something is off" — on a working
    /// connection it read as a warning. Blue says "through VK" without claiming
    /// anything is wrong.
    private var statusColour: Color {
        switch orbState {
        case .off: .white.opacity(0.35)
        case .connecting: MainScreen.amber
        case .on: flow.usesRelay ? MainScreen.blue : MainScreen.accent
        }
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// The wash of colour behind everything, which is how the screen reports status
/// before any text is read.
struct MainScreenAura: View {
    let orbState: ConnectionOrb.State
    let usesRelay: Bool

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 460, height: 460)
            .blur(radius: 70)
            .opacity(opacity)
            .offset(y: -120)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .animation(MainScreen.auraFade, value: orbState)
    }

    private var colour: Color {
        switch orbState {
        case .off: Color(hex: 0x7896BE).opacity(0.28)
        case .connecting: MainScreen.amber.opacity(0.38)
        case .on: MainScreen.accent.opacity(0.5)
        }
    }

    private var opacity: Double {
        switch orbState {
        case .off: 0.5
        case .connecting: 0.9
        case .on: 1
        }
    }
}
