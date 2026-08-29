//
//  ServerRow.swift
//  Turn
//

import SwiftUI

/// One server, drawn the same way wherever it appears.
///
/// The main screen and the pro Proxies tab used to draw the same thing two
/// different ways — a tidy card on one, four coloured badges on the other. This
/// is the one row both of them use now.
struct ServerRowLabel: View {
    /// The name as stored, flag emoji and all — it gets split here.
    let name: String
    /// Protocol, transport, security, extras: one monospaced line.
    let stack: String
    let latency: LatencyResult?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(ServerName.flag(of: name) ?? "🌐")
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: MainScreen.flagTileRadius)
                        .fill(MainScreen.surface(0.06))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(ServerName.plain(of: name))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? .white : MainScreen.surface(0.82))
                    .lineLimit(1)
                Text(stack)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MainScreen.surface(0.34))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            LatencyGauge(result: latency)

            ZStack {
                Circle()
                    .fill(isSelected ? MainScreen.accent : .clear)
                    .overlay(Circle().stroke(isSelected ? .clear : MainScreen.surface(0.18), lineWidth: 1.5))
                    .frame(width: 22, height: 22)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MainScreen.onAccent)
                }
            }
        }
    }
}

/// Milliseconds and a three-bar gauge — the part that is read at a glance.
struct LatencyGauge: View {
    let result: LatencyResult?

    var body: some View {
        HStack(spacing: 6) {
            switch result {
            case .success(let milliseconds):
                Text("\(milliseconds)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(MainScreen.surface(0.55))
                bars(lit: Self.strength(milliseconds), tint: MainScreen.accent)
            case .testing:
                ProgressView().controlSize(.mini).tint(MainScreen.surface(0.4))
            case .failed, .insecure:
                bars(lit: 0, tint: MainScreen.red)
            case nil:
                bars(lit: 0, tint: MainScreen.surface(0.2))
            }
        }
    }

    private func bars(lit: Int, tint: Color) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array([4.0, 6.5, 9.0].enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? tint : MainScreen.surface(0.14))
                    .frame(width: 3, height: height)
            }
        }
    }

    private static func strength(_ milliseconds: Int) -> Int {
        switch milliseconds {
        case ..<80: 3
        case ..<160: 2
        default: 1
        }
    }
}

/// Server names arrive with their flag already in them — `🇩🇪 Германия` — so the
/// tile takes the emoji and the label takes the rest.
enum ServerName {
    static func flag(of name: String) -> String? {
        let scalars = name.unicodeScalars.prefix { $0.properties.isEmoji || $0.properties.isEmojiModifier }
        let flag = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return flag.isEmpty ? nil : flag
    }

    static func plain(of name: String) -> String {
        guard let flag = flag(of: name) else { return name }
        return name.dropFirst(flag.count).trimmingCharacters(in: .whitespaces)
    }
}
