//
//  ServerGroupCard.swift
//  Turn
//

import SwiftUI

/// One group of servers — a subscription, or the ones added by hand.
///
/// The old list put four coloured protocol pills on every row. This is the same
/// information as one monospaced line, which is what makes twenty servers
/// readable at a glance instead of a wall of badges.
struct ServerGroupCard: View {
    let title: String
    let configurations: [ProxyConfiguration]
    let selectedID: UUID?
    let latencies: [UUID: LatencyResult]
    let isRefreshing: Bool
    let isTestingLatency: Bool
    @Binding var isExpanded: Bool
    var onSelect: (ProxyConfiguration) -> Void
    /// Nil for groups that have nothing to refresh — servers added by hand.
    var onRefresh: (() -> Void)?
    var onTestLatency: () -> Void

    @SwiftUI.State private var spinning = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                ForEach(configurations) { configuration in
                    Divider().overlay(MainScreen.surface(0.05))
                    row(configuration)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MainScreen.cardRadius)
                .fill(MainScreen.surface(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: MainScreen.cardRadius)
                        .stroke(MainScreen.surface(0.07), lineWidth: 1)
                )
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(MainScreen.accent)
                .frame(width: 8, height: 8)
                .shadow(color: MainScreen.accent.opacity(0.7), radius: 4)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MainScreen.title)
                .lineLimit(1)

            Text(configurations.count.formatted())
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(MainScreen.surface(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 8).fill(MainScreen.surface(0.07)))

            Spacer(minLength: 4)

            if let onRefresh {
                iconButton(systemImage: "arrow.trianglehead.clockwise", tint: MainScreen.blue, busy: isRefreshing) {
                    onRefresh()
                }
                .rotationEffect(.degrees(isRefreshing && spinning ? 360 : 0))
                .onChange(of: isRefreshing) { _, refreshing in
                    spinning = false
                    guard refreshing else { return }
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                }
            }

            iconButton(systemImage: "speedometer", tint: MainScreen.accent, busy: isTestingLatency) {
                onTestLatency()
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MainScreen.surface(0.4))
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) { isExpanded.toggle() }
        }
    }

    private func iconButton(systemImage: String, tint: Color, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: MainScreen.iconTileRadius).fill(tint.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .opacity(busy ? 0.5 : 1)
        .disabled(busy)
    }

    // MARK: Row

    private func row(_ configuration: ProxyConfiguration) -> some View {
        let selected = configuration.id == selectedID
        return ServerRowLabel(
            name: configuration.name,
            stack: Self.stack(of: configuration),
            latency: latencies[configuration.id],
            isSelected: selected
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(selected ? MainScreen.surface(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(configuration) }
    }

    // MARK: Naming

    private static func stack(of configuration: ProxyConfiguration) -> String {
        var parts = [configuration.outboundProtocol.rawValue.uppercased()]
        if configuration.turn != nil { parts.append("TURN") }
        return parts.joined(separator: " · ")
    }

}
