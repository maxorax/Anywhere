//
//  OnboardingView.swift
//  Turn
//

import SwiftUI

/// The two questions worth asking before the first connection.
///
/// Both were in the app's original onboarding and were lost in the rename; this
/// is that flow again, in the redesigned screen's colours. The rules database
/// ships with the app, so both answers can be acted on immediately — there is
/// nothing to download first.
struct OnboardingView: View {
    @Environment(RoutingRuleSetStore.self) private var ruleSetStore
    @Binding var completed: Bool

    @State private var bypassCountryCode = AWCore.getBypassCountryCode()

    var body: some View {
        VStack(spacing: 0) {
            countryPage

            bottomBar
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .background {
            LinearGradient(colors: MainScreen.backgroundStops, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // The device language is a good guess at the country worth letting
            // out of the tunnel, and it is only a default — the list is right
            // there to disagree with.
            if bypassCountryCode.isEmpty,
               let suggested = CountryBypassCatalog.shared.suggestedCountryCode() {
                bypassCountryCode = suggested
            }
        }
    }

    // MARK: - Pages

    private var countryPage: some View {
        VStack(spacing: 20) {
            header(
                symbol: "globe.europe.africa.fill",
                tint: MainScreen.blue,
                title: String(localized: "Country Bypass"),
                subtitle: String(localized: "Local sites go straight out instead of through the tunnel — faster, and banks stop objecting to a foreign address.")
            )

            ScrollView {
                VStack(spacing: 0) {
                    choice(title: String(localized: "Disable"), selected: bypassCountryCode.isEmpty) {
                        bypassCountryCode = ""
                    }
                    ForEach(CountryBypassCatalog.shared.supportedCountryCodes, id: \.self) { code in
                        Divider().overlay(MainScreen.surface(0.05))
                        choice(
                            title: "\(Self.flag(for: code)) \(Locale.current.localizedString(forRegionCode: code) ?? code)",
                            selected: bypassCountryCode == code
                        ) {
                            bypassCountryCode = code
                        }
                    }
                }
                .background(card)
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Pieces

    private func header(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MainScreen.title)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(MainScreen.surface(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func choice(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? .white : MainScreen.surface(0.82))
                Spacer()
                ZStack {
                    Circle()
                        .fill(selected ? MainScreen.accent : .clear)
                        .overlay(Circle().stroke(selected ? .clear : MainScreen.surface(0.18), lineWidth: 1.5))
                        .frame(width: 22, height: 22)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MainScreen.onAccent)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: MainScreen.settingsCardRadius)
            .fill(MainScreen.surface(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: MainScreen.settingsCardRadius)
                    .stroke(MainScreen.surface(0.07), lineWidth: 1)
            )
    }

    private var bottomBar: some View {
        HStack {
            Spacer()

            // Ad blocking is not asked here any more: it is one toggle in
            // Settings, and a second page for it made a first launch feel like a
            // questionnaire.
            Button(action: finish) {
                Text("Get Started")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MainScreen.onAccent)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(MainScreen.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func finish() {
        ruleSetStore.bypassCountryCode = bypassCountryCode
        AWCore.setOnboardingCompleted(true)
        withAnimation { completed = true }
    }

    private static func flag(for countryCode: String) -> String {
        String(countryCode.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(Character.init))
    }
}
