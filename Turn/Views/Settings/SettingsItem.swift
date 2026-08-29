//
//  SettingsItem.swift
//  Turn
//
//  Created by NodePassProject on 6/20/26.
//

import SwiftUI

enum SettingsItem: String {
    case iCloudSync
    case personalization
    case subscriptionUpdate
    case alwaysOn
    case globalMode
    case adBlocking
    case countryBypass
    case routingRules
    case allowInsecure
    case trustedCertificates
    case trustedNetwork
    case turn
    case purify
    case reflection
    case mitm
    case logs
    case requests
    case about
    case proMode

    private var title: String.LocalizationValue {
        switch self {
        case .iCloudSync: "iCloud Sync"
        case .personalization: "Personalization"
        case .subscriptionUpdate: "Update Subscriptions"
        case .alwaysOn: "Always On"
        case .globalMode: "Global Mode"
        case .adBlocking: "AD Blocking"
        case .countryBypass: "Country Bypass"
        case .routingRules: "Routing Rules"
        case .allowInsecure: "Allow Insecure"
        case .trustedCertificates: "Trusted Certificates"
        case .trustedNetwork: "Trusted Network"
        case .turn: "VK TURN"
        case .purify: "Purify"
        case .reflection: "Reflection"
        case .mitm: "MITM"
        case .logs: "Logs"
        case .requests: "Requests"
        case .about: "About"
        case .proMode: "Pro Mode"
        }
    }

    private var systemName: String {
        switch self {
        case .iCloudSync: "icloud.fill"
        case .personalization: "paintpalette.fill"
        case .subscriptionUpdate: "arrow.clockwise"
        case .alwaysOn: "poweron"
        case .globalMode: "arrow.merge"
        case .adBlocking: "shield.checkered"
        case .countryBypass: "globe.americas.fill"
        case .routingRules: "arrow.triangle.branch"
        case .allowInsecure: "exclamationmark.shield.fill"
        case .trustedCertificates: "checkmark.seal.fill"
        case .trustedNetwork: "wifi"
        case .turn: "phone.arrow.up.right.fill"
        case .purify: "drop.fill"
        case .reflection: "arrow.turn.up.left"
        case .mitm: "key.horizontal.fill"
        case .logs:
            if #available(iOS 18.4, *) {
                "info.circle.text.page.fill"
            } else {
                "info"
            }
        case .requests: "mail.fill"
        case .about: "info.circle.fill"
        case .proMode: "wrench.and.screwdriver.fill"
        }
    }

    private var foregroundColor: Color {
        switch self {
        case .iCloudSync: .blue
        default: .white
        }
    }

    private var backgroundColor: Color {
        switch self {
        case .iCloudSync: .white
        case .personalization: .pink
        case .subscriptionUpdate: .teal
        case .alwaysOn: .green
        case .globalMode: .orange
        case .adBlocking: .red
        case .countryBypass: .blue
        case .routingRules: .purple
        case .allowInsecure: .red
        case .trustedCertificates: .green
        case .trustedNetwork: .blue
        case .turn: .indigo
        case .purify: .blue
        case .reflection: .pink
        case .mitm: .mint
        case .logs: .blue
        case .requests: .blue
        case .about: .gray
        case .proMode: .indigo
        }
    }

    var label: some View {
        TextWithColorfulIcon(
            title: title,
            comment: nil,
            systemName: systemName,
            foregroundStyle: foregroundColor,
            backgroundStyle: backgroundColor.gradient
        )
    }

    /// The same row in the redesigned style: the tile is the tint at low alpha
    /// and the symbol is the tint itself, rather than white on a solid block of
    /// colour. Kept beside ``label`` rather than replacing it, so the old look
    /// is one call away.
    ///
    /// `iCloudSync` is the odd one out in the old scheme, painting a white tile
    /// with a blue glyph, so the tint is whichever of the two is not white.
    var tileLabel: some View {
        let tint = backgroundColor == .white ? foregroundColor : backgroundColor
        return HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: MainScreen.iconTileRadius)
                        .fill(tint.opacity(0.26))
                )
            Text(String(localized: title))
        }
    }
}
