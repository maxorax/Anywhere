//
//  ConnectionOrb.swift
//  Turn
//

import SwiftUI

/// The power button: the screen's centre of gravity.
///
/// Deliberately quiet. The handoff had rings pulsing outward from it and took
/// them back out — what is left is the body's slow breath, a contour ring that
/// fades in only once traffic is flowing, and a spinner while it is not yet.
struct ConnectionOrb: View {
    enum State: Equatable {
        case off
        case connecting
        case on
    }

    let state: State
    var action: () -> Void
    /// Holding the button connects through the VK relay, whatever the setting.
    var onHold: () -> Void = {}

    private static let size: CGFloat = 158
    private static let bodyInset: CGFloat = 8
    private static let hairlineInset: CGFloat = 20
    private static let coreSize: CGFloat = 62

    @SwiftUI.State private var breathing = false
    @SwiftUI.State private var spinning = false

    var body: some View {
        ZStack {
            contourRing
            body_
            hairline
            core
            glyph
            if state == .connecting { spinner }
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .powerButtonGestures(onTap: action, onHold: onHold)
        // Not disabled while connecting on purpose. Bringing a tunnel up can
        // take minutes — a relay parked on a captcha is the worst of it — and a
        // button that ignores taps then is a dead end with no way out.
        .animation(MainScreen.auraFade, value: state)
        .onAppear {
            withAnimation(MainScreen.breathe) { breathing = true }
        }
    }

    // MARK: Layers

    /// Visible only once connected, so the ring reads as "this is up" rather
    /// than decoration.
    private var contourRing: some View {
        Circle()
            .stroke(MainScreen.accent, lineWidth: 1)
            .opacity(state == .on ? 0.35 : 0)
            .animation(.easeInOut(duration: 0.6), value: state)
    }

    private var body_: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.1), .white.opacity(0.02), .black.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
            .padding(Self.bodyInset)
            .shadow(color: shadowColour, radius: shadowRadius, y: state == .off ? 20 : 0)
            .scaleEffect(breathing ? 1.03 : 1)
    }

    private var hairline: some View {
        Circle()
            .stroke(.white.opacity(0.05), lineWidth: 1)
            .padding(Self.hairlineInset)
    }

    private var core: some View {
        Circle()
            .fill(state == .on ? MainScreen.accent.opacity(0.16) : .white.opacity(0.05))
            .frame(width: Self.coreSize, height: Self.coreSize)
    }

    private var glyph: some View {
        PowerGlyph()
            .stroke(glyphColour, style: StrokeStyle(lineWidth: 1.8 * (34 / 24), lineCap: .round))
            .frame(width: 34, height: 34)
    }

    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(MainScreen.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(Self.bodyInset)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .onDisappear { spinning = false }
    }

    // MARK: Styling

    private var glyphColour: Color {
        switch state {
        case .off: .white.opacity(0.75)
        case .connecting: MainScreen.amber
        case .on: MainScreen.accent
        }
    }

    private var shadowColour: Color {
        switch state {
        case .off: .black.opacity(0.45)
        case .connecting: MainScreen.amber.opacity(0.28)
        case .on: MainScreen.accent.opacity(0.35)
        }
    }

    private var shadowRadius: CGFloat {
        switch state {
        case .off: 25
        case .connecting: 25
        case .on: 30
        }
    }
}

// MARK: - Tap and hold

extension View {
    /// Tap toggles the tunnel; holding connects through the VK relay.
    ///
    /// Not a `Button` with a long press bolted on: a button still fires its
    /// action when the finger lifts after a hold, so one gesture would both
    /// force the relay and toggle the tunnel straight back off. Here the hold is
    /// tried first and the tap only counts if the hold never completed.
    func powerButtonGestures(onTap: @escaping () -> Void, onHold: @escaping () -> Void) -> some View {
        modifier(PowerButtonGestures(onTap: onTap, onHold: onHold))
    }
}

private struct PowerButtonGestures: ViewModifier {
    private static let holdDuration: TimeInterval = 0.6

    let onTap: () -> Void
    let onHold: () -> Void

    /// Bumped on every completed hold, so the haptic says "that was the other
    /// action" before anything on screen has had time to change.
    @State private var holds = 0

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: Self.holdDuration)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first:
                            holds += 1
                            onHold()
                        case .second:
                            onTap()
                        }
                    }
            )
            .sensoryFeedback(.impact(weight: .medium), trigger: holds)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onTap() }
            .accessibilityAction(named: Text("Connect through VK")) { onHold() }
    }
}

/// The power mark: a ring open at the top with a stem through the gap.
///
/// Traced from the handoff's own path in a 24-unit box — `M12 3.5 L12 11` and
/// an arc of radius 7.5 taking the long way round from upper-left to
/// upper-right, which is what leaves the 90° gap at the top.
// `nonisolated` because the conformance is otherwise inferred as main-actor
// isolated, which Xcode 27 rejects: `Shape` may be rasterised off the main
// actor. Nothing here touches shared state — it is arithmetic on a rect.
private struct PowerGlyph: Shape {
    nonisolated init() {}

    nonisolated func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        path.move(to: CGPoint(x: 12 * unit, y: 3.5 * unit))
        path.addLine(to: CGPoint(x: 12 * unit, y: 11 * unit))
        path.move(to: CGPoint(x: 6.6 * unit, y: 6.6 * unit))
        path.addArc(
            center: CGPoint(x: 12 * unit, y: 12 * unit),
            radius: 7.5 * unit,
            startAngle: .degrees(225),
            endAngle: .degrees(315),
            clockwise: true
        )
        return path
    }
}
