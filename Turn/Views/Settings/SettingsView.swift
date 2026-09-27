//
//  SettingsView.swift
//  Turn
//
//  Created by NodePassProject on 2/21/26.
//

import SwiftUI
import WidgetKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(RoutingRuleSetStore.self) private var ruleSetStore

    @State private var adBlockEnabled = RoutingRuleSetStore.shared.adBlockRuleSet?.assignedConfigurationId == "REJECT"

    @State private var subscriptionRefreshOnOpen = AWCore.getSubscriptionRefreshOnOpen()
    @State private var showICloudRestartAlert = false
    @State private var showInsecureAlert = false

    var body: some View {
        Form {
            appSection
            vpnSection
            routingSection
            securitySection
            utilitiesSection
            diagnosisSection
            aboutSection
            footer
        }
        // Styled to match the redesigned main screen rather than rebuilt: the
        // rows, their destinations and their icon colours are the ones that were
        // already here, on the new surfaces.
        .listRowBackground(MainScreen.surface(0.035))
        .listRowSeparatorTint(MainScreen.surface(0.05))
        .scrollContentBackground(.hidden)
        .background {
            LinearGradient(colors: MainScreen.backgroundStops, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .tint(MainScreen.accent)
        .navigationTitle("Settings")
        .onChange(of: adBlockEnabled) { _, newValue in
            if let adBlockRuleSet = RoutingRuleSetStore.shared.adBlockRuleSet {
                RoutingRuleSetStore.shared.updateAssignment(adBlockRuleSet, configurationId: newValue ? "REJECT" : nil)
            }
        }
        .onChange(of: settings.iCloudSyncEnabled) { _, newValue in
            showICloudRestartAlert = newValue != JSONBlobStore.shared.usesCloudKit
        }
        .onAppear {
            adBlockEnabled = RoutingRuleSetStore.shared.adBlockRuleSet?.assignedConfigurationId == "REJECT"
        }
        .alert("Restart Required", isPresented: $showICloudRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restart Turn for the change to take effect.")
        }
        .alert("Allow Insecure", isPresented: $showInsecureAlert) {
            Button("Allow Anyway", role: .destructive) {
                settings.allowInsecure = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will skip TLS certificate validation, making your connections vulnerable to MITM attacks.")
        }
    }
    
    /// Version line closing the list, as on the handoff's settings tab.
    private var footer: some View {
        Section {
        } footer: {
            Text(verbatim: Self.versionLine)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(MainScreen.surface(0.25))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Turn \(version) (\(build))"
    }

    @ViewBuilder
    private var appSection: some View {
        @Bindable var settings = settings
        Section("App") {
            Toggle(isOn: $settings.proMode) {
                SettingsItem.proMode.tileLabel
            }
            if settings.proMode {
                Toggle(isOn: $settings.iCloudSyncEnabled) {
                    SettingsItem.iCloudSync.tileLabel
                }
                NavigationLink {
                    PersonalizationSettingsView()
                } label: {
                    SettingsItem.personalization.tileLabel
                }
            }
            Toggle(isOn: $subscriptionRefreshOnOpen) {
                SettingsItem.subscriptionUpdate.tileLabel
            }
            .onChange(of: subscriptionRefreshOnOpen) {
                AWCore.setSubscriptionRefreshOnOpen(subscriptionRefreshOnOpen)
                SubscriptionAutoUpdater.shared.refreshOnOpen()
            }
        }
    }

    @ViewBuilder
    private var vpnSection: some View {
        @Bindable var settings = settings
        if settings.proMode {
            Section("VPN") {
                Toggle(isOn: $settings.alwaysOnEnabled) {
                    SettingsItem.alwaysOn.tileLabel
                }
                .disabled(viewModel.pendingReconnect)
            }
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        @Bindable var settings = settings
        // Global mode is a pro switch, and it hides everything else in here —
        // so outside pro mode with it left on there is nothing to show.
        if settings.proMode || !settings.isGlobalMode {
            Section("Routing") {
                if settings.proMode {
                    Toggle(isOn: $settings.isGlobalMode) {
                        SettingsItem.globalMode.tileLabel
                    }
                    .onChange(of: settings.isGlobalMode) {
                        ControlCenter.shared.reloadControls(ofKind: "com.maxorax.turn.Widget.VPNToggle")
                    }
                }
                if !settings.isGlobalMode {
                    // Not pro-only: both are asked about in the onboarding, so
                    // hiding them afterwards left no way to change the answer.
                    Toggle(isOn: $adBlockEnabled) {
                        SettingsItem.adBlocking.tileLabel
                    }
                    countryBypassPicker
                    NavigationLink {
                        RuleSetListView()
                    } label: {
                        SettingsItem.routingRules.tileLabel
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var countryBypassPicker: some View {
        @Bindable var ruleSetStore = ruleSetStore
        Picker(selection: $ruleSetStore.bypassCountryCode) {
            Text("Disable").tag("")
            ForEach(CountryBypassCatalog.shared.supportedCountryCodes, id: \.self) { code in
                Text(countryLabel(for: code)).tag(code)
            }
        } label: {
            SettingsItem.countryBypass.tileLabel
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        if settings.proMode {
            Section("Security") {
                Toggle(isOn: Binding(
                    get: { settings.allowInsecure },
                    set: { newValue in
                        if newValue {
                            showInsecureAlert = true
                        } else {
                            settings.allowInsecure = false
                        }
                    }
                )) {
                    SettingsItem.allowInsecure.tileLabel
                }
                .tint(.red)
                NavigationLink {
                    TrustedCertificatesView()
                } label: {
                    SettingsItem.trustedCertificates.tileLabel
                }
                NavigationLink {
                    TrustedNetworkSettingsView()
                } label: {
                    SettingsItem.trustedNetwork.tileLabel
                }
                NavigationLink {
                    TurnSettingsView()
                } label: {
                    SettingsItem.turn.tileLabel
                }
            }
        }
    }

    @ViewBuilder
    private var utilitiesSection: some View {
        if settings.proMode {
            Section("Utilities") {
                NavigationLink {
                    PurifySettingsView()
                } label: {
                    SettingsItem.purify.tileLabel
                }
                NavigationLink {
                    ReflectionSettingsView()
                } label: {
                    SettingsItem.reflection.tileLabel
                }
                NavigationLink {
                    MITMSettingsView()
                } label: {
                    SettingsItem.mitm.tileLabel
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosisSection: some View {
        Section("Diagnostics") {
            NavigationLink {
                LogListView()
            } label: {
                SettingsItem.logs.tileLabel
            }
            NavigationLink {
                RequestsView()
            } label: {
                SettingsItem.requests.tileLabel
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                SettingsItem.about.tileLabel
            }
        } footer: {
            if settings.proMode {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    HStack {
                        Text("Advanced Settings")
                            .font(.body)
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func flag(for countryCode: String) -> String {
        String(countryCode.unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
        }.map(Character.init))
    }

    private func countryLabel(for code: String) -> String {
        let name = Locale.current.localizedString(forRegionCode: code) ?? code
        return "\(flag(for: code)) \(name)"
    }
}
