//
//  ProxyRowTile.swift
//  Turn
//

import SwiftUI

/// The pro Proxies row in the redesigned style.
///
/// Same inputs and same actions as ``ProxyRowView``, which is untouched and
/// still compiles — swapping back is one line in `ProxiesPageView`. The
/// difference is the body: a flag tile, one monospaced line where four coloured
/// badges used to be, and the latency gauge the main screen uses.
struct ProxyRowTile: View {
    let item: ProxyListItem
    let editingDisabled: Bool
    let onSelect: () -> Void
    let onTestLatency: () -> Void
    let onCopyLink: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ServerRowLabel(
                name: item.name,
                stack: Self.stack(of: item),
                latency: item.latency,
                isSelected: item.isSelected
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onTestLatency) {
                Label("Test Latency", systemImage: "gauge.with.dots.needle.67percent")
            }
            if !editingDisabled {
                Button(action: onCopyLink) {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Protocol, transport, security and the extras, in the order the row used
    /// to show them as badges.
    private static func stack(of item: ProxyListItem) -> String {
        var parts = [item.protocolName]
        if let transport = item.transportLayerTag { parts.append(transport) }
        if let security = item.securityLayerTag { parts.append(security) }
        if item.isVision { parts.append("Vision") }
        if item.hasTurn { parts.append("TURN") }
        return parts.joined(separator: " · ")
    }
}
