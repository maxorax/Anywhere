//
//  StageFlow.swift
//  Turn
//

import SwiftUI

/// The connection sequence as the main screen draws it.
///
/// Six steps, each one a real thing the tunnel does rather than a placeholder:
/// the provider reports the first four through ``TunnelStage`` and the relay
/// reports the last two through ``TurnState``. The branch to the right is the
/// only part that is conditional — it is what a connection through VK costs.
nonisolated struct StageFlow: Equatable {

    enum Node: CaseIterable {
        /// Configuration resolved, tunnel settings applied.
        case profile
        /// Measuring the direct path, to see whether a relay is needed at all.
        case probe
        /// The decision: straight out, or through VK.
        case route
        /// The relay coming up — credentials, allocations, lanes.
        case relay
        /// VK stopped to ask for a captcha.
        case captcha
        /// Traffic is flowing.
        case connected

        var title: String {
            switch self {
            case .profile: String(localized: "Profile")
            case .probe: String(localized: "Probe")
            case .route: String(localized: "Route")
            case .relay: String(localized: "Relay")
            case .captcha: String(localized: "Captcha")
            case .connected: String(localized: "Connected")
            }
        }

        /// True for the two that sit on the branch rather than the main line.
        var isOnBranch: Bool { self == .relay || self == .captcha }
    }

    enum State: Equatable {
        /// Behind us.
        case done
        /// Happening right now.
        case active
        /// Not reached yet.
        case pending
        /// Reached and went wrong — the relay failed, or a captcha was refused.
        case failed
    }

    var stage: TunnelStage
    var path: TunnelPath?
    var relay: TurnState
    /// Set once VK has asked for a captcha in this attempt, so the node can read
    /// as done afterwards rather than falling back to untouched.
    var captchaSeen: Bool

    /// Whether the branch is the one this connection actually takes. Before the
    /// route is decided it is a guess — the relay mode is the best one there is,
    /// and the chart only dims the branch on it, never colours it.
    var usesRelay: Bool { path == .turn }

    func state(of node: Node) -> State {
        switch node {
        case .profile: return step(reached: stage.rank >= TunnelStage.profile.rank,
                                   active: stage == .profile)
        case .probe: return step(reached: stage.rank >= TunnelStage.probe.rank,
                                 active: stage == .probe)
        case .route: return step(reached: stage.rank >= TunnelStage.route.rank,
                                 active: stage == .route)
        case .relay:
            guard usesRelay else { return .pending }
            if relay.phase == .error { return .failed }
            if relay.phase == .ready || stage == .connected { return .done }
            return stage.rank >= TunnelStage.relay.rank ? .active : .pending
        case .captcha:
            guard usesRelay else { return .pending }
            if relay.phase == .captcha { return .active }
            return captchaSeen ? .done : .pending
        case .connected:
            if stage == .failed { return .failed }
            return step(reached: stage == .connected, active: false)
        }
    }

    private func step(reached: Bool, active: Bool) -> State {
        if active { return .active }
        return reached ? .done : .pending
    }
}

// MARK: - Chart

/// The flow chart standing to the left of the power button.
///
/// Always on screen, including at rest — the point is that the path is readable
/// before anything happens, not only while it is happening. Drawn at the
/// handoff's own coordinates in a 100×196 box, so the geometry can be checked
/// against the spec line by line.
struct StageFlowChart: View {
    let flow: StageFlow
    /// Tapping the captcha node reopens the page VK is waiting on. The stage
    /// toast used to be the way back into a dismissed captcha; this replaced it.
    var onCaptcha: () -> Void = {}

    private static let size = CGSize(width: 100, height: 196)
    private static let mainX: CGFloat = 20
    private static let branchX: CGFloat = 74

    var body: some View {
        ZStack(alignment: .topLeading) {
            lines
            node(.profile, at: CGPoint(x: Self.mainX, y: 10), radius: 6)
            node(.probe, at: CGPoint(x: Self.mainX, y: 44), radius: 6)
            diamond(at: CGPoint(x: Self.mainX, y: 82))
            pill(.relay, top: 110)
            pill(.captcha, top: 140)
            node(.connected, at: CGPoint(x: Self.mainX, y: 181), radius: 6.5)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .animation(MainScreen.stageFade, value: flow)
    }

    // MARK: Lines

    private var lines: some View {
        ZStack {
            segment(from: CGPoint(x: 20, y: 17), to: CGPoint(x: 20, y: 37), lit: reached(.profile))
            segment(from: CGPoint(x: 20, y: 51), to: CGPoint(x: 20, y: 73), lit: reached(.probe))
            segment(from: CGPoint(x: 20, y: 91), to: CGPoint(x: 20, y: 100), lit: reached(.route))
            // The fork and the return are lit only for the path actually taken,
            // so a direct connection leaves the branch dark rather than implying
            // traffic went through it.
            segment(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 74, y: 100), lit: reached(.route) && flow.usesRelay)
            segment(from: CGPoint(x: 74, y: 100), to: CGPoint(x: 74, y: 110), lit: reached(.route) && flow.usesRelay)
            segment(from: CGPoint(x: 74, y: 130), to: CGPoint(x: 74, y: 140), lit: reached(.relay) && flow.usesRelay)
            segment(from: CGPoint(x: 74, y: 160), to: CGPoint(x: 74, y: 166), lit: reached(.captcha) && flow.usesRelay)
            segment(from: CGPoint(x: 20, y: 166), to: CGPoint(x: 74, y: 166), lit: reached(.captcha) && flow.usesRelay)
            segment(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 20, y: 166), lit: reached(.route) && !flow.usesRelay)
            segment(from: CGPoint(x: 20, y: 166), to: CGPoint(x: 20, y: 174), lit: reached(.connected))
        }
    }

    private func segment(from start: CGPoint, to end: CGPoint, lit: Bool) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(lit ? MainScreen.accent : MainScreen.surface(0.09),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private func reached(_ node: StageFlow.Node) -> Bool {
        switch flow.state(of: node) {
        case .done, .active: true
        case .pending, .failed: false
        }
    }

    // MARK: Nodes

    private func node(_ node: StageFlow.Node, at centre: CGPoint, radius: CGFloat) -> some View {
        let state = flow.state(of: node)
        return ZStack {
            if state == .active {
                Circle()
                    .fill(MainScreen.amber.opacity(0.5))
                    .frame(width: (radius + 3.5) * 2, height: (radius + 3.5) * 2)
                    .blur(radius: 3)
            }
            Circle()
                .fill(state == .done ? MainScreen.accent : .clear)
                .overlay(Circle().stroke(stroke(state), lineWidth: 1.4))
                .frame(width: radius * 2, height: radius * 2)
            if state == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: radius, weight: .bold))
                    .foregroundStyle(MainScreen.onAccent)
            }
        }
        .position(centre)
        .overlay(alignment: .topLeading) {
            label(node, state: state)
                .offset(x: 33, y: centre.y - 7)
        }
    }

    private func diamond(at centre: CGPoint) -> some View {
        let state = flow.state(of: .route)
        return ZStack {
            if state == .active {
                Circle()
                    .fill(MainScreen.amber.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .blur(radius: 3)
            }
            Rectangle()
                .fill(state == .done ? MainScreen.accent : .clear)
                .overlay(Rectangle().stroke(stroke(state), lineWidth: 1.4))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(45))
        }
        .position(centre)
        .overlay(alignment: .topLeading) {
            label(.route, state: state).offset(x: 33, y: centre.y - 7)
        }
    }

    private func pill(_ node: StageFlow.Node, top: CGFloat) -> some View {
        let state = flow.state(of: node)
        let idle = state == .pending && !flow.usesRelay
        return Text(node.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(pillText(state))
            .frame(width: 46, height: 20)
            .background(
                RoundedRectangle(cornerRadius: MainScreen.stagePillRadius)
                    .fill(pillFill(state))
                    .overlay(
                        RoundedRectangle(cornerRadius: MainScreen.stagePillRadius)
                            .stroke(pillBorder(state), lineWidth: 1)
                    )
            )
            // Dimmed rather than hidden: the branch stays readable as the road
            // not taken.
            .opacity(idle ? 0.4 : 1)
            .offset(x: 51, y: top)
            .contentShape(RoundedRectangle(cornerRadius: MainScreen.stagePillRadius))
            .onTapGesture { if node == .captcha, state == .active { onCaptcha() } }
    }

    // MARK: Styling

    private func stroke(_ state: StageFlow.State) -> Color {
        switch state {
        case .done: MainScreen.accent
        case .active: MainScreen.amber
        case .failed: MainScreen.amber
        case .pending: MainScreen.surface(0.16)
        }
    }

    private func pillFill(_ state: StageFlow.State) -> Color {
        switch state {
        case .done: MainScreen.accent.opacity(0.15)
        case .active: MainScreen.surface(0.06)
        case .failed: MainScreen.amber.opacity(0.13)
        case .pending: .clear
        }
    }

    private func pillBorder(_ state: StageFlow.State) -> Color {
        switch state {
        case .done: MainScreen.accent.opacity(0.45)
        case .active: MainScreen.amber.opacity(0.6)
        case .failed: MainScreen.amber.opacity(0.5)
        case .pending: MainScreen.surface(0.12)
        }
    }

    private func pillText(_ state: StageFlow.State) -> Color {
        switch state {
        case .done: MainScreen.accent
        case .active: .white
        case .failed: MainScreen.amber
        case .pending: MainScreen.surface(0.32)
        }
    }

    private func label(_ node: StageFlow.Node, state: StageFlow.State) -> some View {
        Text(node.title)
            .font(.system(size: 10.5))
            .kerning(-0.1)
            .foregroundStyle(labelColour(state))
            .fixedSize()
    }

    private func labelColour(_ state: StageFlow.State) -> Color {
        switch state {
        case .done: MainScreen.surface(0.55)
        case .active: .white
        case .failed: MainScreen.amber
        case .pending: MainScreen.surface(0.34)
        }
    }
}
