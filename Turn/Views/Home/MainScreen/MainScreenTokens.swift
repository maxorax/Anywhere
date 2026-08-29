//
//  MainScreenTokens.swift
//  Turn
//

import SwiftUI

/// The redesigned main screen's palette, radii and type scale.
///
/// The handoff specifies colours in `oklch`, which SwiftUI has no initialiser
/// for; each one is converted to sRGB once here and the original kept beside it,
/// so a value can be checked against the spec without re-deriving it.
nonisolated enum MainScreen {

    // MARK: - Colour

    /// Everything is well: connected, a stage that passed, a filled toggle.
    /// `oklch(0.78 0.13 165)`
    static let accent = Color(hex: 0x56D1A3)
    /// In progress, routed through VK, or degraded. `oklch(0.82 0.13 80)`
    static let amber = Color(hex: 0xF0BA59)
    /// Text dark enough to read on top of ``accent``.
    static let onAccent = Color(hex: 0x08110D)

    static let blue = Color(hex: 0x4BA3F7)      // oklch(0.70 0.15 250)
    static let indigo = Color(hex: 0x8A7FF4)    // oklch(0.66 0.17 285)
    static let pink = Color(hex: 0xF55A7D)      // oklch(0.68 0.19 10)
    static let red = Color(hex: 0xF0574E)       // oklch(0.66 0.19 27)
    static let orange = Color(hex: 0xF2943C)    // oklch(0.75 0.15 60)
    static let teal = Color(hex: 0x00C7C7)      // oklch(0.75 0.13 195)

    /// Screen background, top to bottom.
    static let backgroundStops = [Color(hex: 0x171D25), Color(hex: 0x0F141A), Color(hex: 0x0C1015)]

    /// Raised surfaces — cards, pills, icon tiles — as white at low alpha.
    static func surface(_ alpha: Double) -> Color { .white.opacity(alpha) }

    static let title = Color(hex: 0xF2F5F8)
    static let rowTitle = Color(hex: 0xEAEFF4)

    // MARK: - Shape

    static let cardRadius: CGFloat = 24
    static let settingsCardRadius: CGFloat = 20
    static let tabBarRadius: CGFloat = 22
    static let tabPillRadius: CGFloat = 17
    static let headerButtonRadius: CGFloat = 19
    static let toggleRadius: CGFloat = 14
    static let flagTileRadius: CGFloat = 11
    static let iconTileRadius: CGFloat = 10
    static let stagePillRadius: CGFloat = 7

    // MARK: - Motion

    /// The orb's slow scale, and the pulse of a stage that is happening now.
    static let breathe = Animation.easeInOut(duration: 5).repeatForever(autoreverses: true)
    static let stageBreathe = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
    /// Colour transitions, per the handoff: aura, shadow, core, status text, nodes.
    static let auraFade = Animation.easeInOut(duration: 0.8)
    static let statusFade = Animation.easeInOut(duration: 0.5)
    static let stageFade = Animation.easeInOut(duration: 0.35)
}
