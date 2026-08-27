//
//  Color+Theme.swift
//  Turn
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Default home-screen gradient colours.
//
// Upstream generates these symbols from an asset catalog, but no `.xcassets`
// is present in the published repository, so `Color.connectedBackgroundStart`
// and friends fail to resolve and the app target does not build. These are
// stand-in values with the same names; the user-facing colours are overridable
// at runtime anyway — see `AWCore.ThemeColorSlot` and the
// `settings.connectedBackground*Data` overrides read in `HomeView`.
nonisolated extension Color {
    static let connectedBackgroundStart = Color(hex: 0x0E7C66)
    static let connectedBackgroundEnd = Color(hex: 0x06301F)
    static let disconnectedBackgroundStart = Color(hex: 0x3A4552)
    static let disconnectedBackgroundEnd = Color(hex: 0x14181D)
}

#if canImport(UIKit)
nonisolated extension UIColor {
    static let connectedBackgroundStart = UIColor(Color.connectedBackgroundStart)
    static let connectedBackgroundEnd = UIColor(Color.connectedBackgroundEnd)
    static let disconnectedBackgroundStart = UIColor(Color.disconnectedBackgroundStart)
    static let disconnectedBackgroundEnd = UIColor(Color.disconnectedBackgroundEnd)
}
#endif
