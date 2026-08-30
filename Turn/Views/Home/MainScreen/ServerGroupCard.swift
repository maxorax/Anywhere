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
    /// Traffic spent over what is left, and when the subscription runs out.
    /// Both come from the panel's `subscription-userinfo` header; a group of
    /// hand-added servers has neither.
    var traffic: String?
    var expiry: String?
    var expired = false
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
    /// Nil for groups that are not subscriptions — nothing to rename or drop.
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            // Its own line rather than a subtitle squeezed under the name: it is
            // what a subscription is judged by.
            if traffic != nil || expiry != nil {
                Divider().overlay(MainScreen.surface(0.05))
                HStack {
                    if let traffic {
                        Text(traffic)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(MainScreen.surface(0.55))
                    }
                    Spacer()
                    if let expiry {
                        Text(expiry)
                            .font(.system(size: 12, weight: expired ? .medium : .regular))
                            .foregroundStyle(expired ? MainScreen.amber : MainScreen.surface(0.55))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
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

            Spacer(minLength: 4)

            if let onRefresh {
                iconButton(systemImage: "arrow.trianglehead.clockwise", tint: MainScreen.blue, busy: isRefreshing) {
                    onRefresh()
                }
            }

            iconButton(systemImage: "speedometer", tint: MainScreen.accent, busy: isTestingLatency) {
                onTestLatency()
            }

            // Renaming and removing a subscription lived on the old list's group
            // header; without them here the only thing a tap on the header did
            // was collapse the group, and a subscription could not be removed at
            // all.
            if onRename != nil || onDelete != nil {
                Menu {
                    if let onRename {
                        Button {
                            onRename()
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MainScreen.surface(0.5))
                        .frame(width: 26, height: 30)
                }
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

    /// A spinner while it works, rather than a spinning icon.
    ///
    /// The icon used to be rotated by a `repeatForever` animation started on
    /// every change of the busy flag. Tapping refresh a few times stacked those
    /// animations — the arrow span faster and faster and never stopped, because
    /// setting the flag back does not cancel a repeating animation.
    private func iconButton(systemImage: String, tint: Color, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: MainScreen.iconTileRadius).fill(tint.opacity(0.22)))
        }
        .buttonStyle(.plain)
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
