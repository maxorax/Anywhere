//
//  MainTabView.swift
//  Turn
//
//  Created by NodePassProject on 6/13/26.
//

import SwiftUI

struct MainTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(RoutingRuleSetStore.self) private var ruleSetStore
    @Environment(DeepLinkManager.self) private var deepLinkManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var captchaModel = TurnCaptchaModel.shared
    @State private var selectedTab: AppTab = .home
    @State private var showingDeepLinkAddSheet = false
    @State private var showingManualAddSheet = false
    @State private var pendingDeepLinkURL: String?
    @State private var showingImportRuleSetsSheet = false
    @State private var pendingRuleSetLinks: [URL] = []
    
    private var showOrphanedAlert: Binding<Bool> {
        Binding(
            get: { !ruleSetStore.orphanedRuleSetNames.isEmpty },
            set: { if !$0 { ruleSetStore.acknowledgeOrphans() } }
        )
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            tabView
            MainScreenTabBar(selection: $selectedTab, showsProxies: settings.proMode)
        }
            .onChange(of: deepLinkManager.url) { _, newValue in
                if let url = newValue {
                    // Outside pro mode there is no Proxies tab to land on.
                    selectedTab = settings.proMode ? .proxies : .home
                    pendingDeepLinkURL = url
                    deepLinkManager.url = nil
                    showingDeepLinkAddSheet = true
                }
            }
            .onChange(of: deepLinkManager.ruleSetLinks) { _, newValue in
                if let links = newValue, !links.isEmpty {
                    selectedTab = .settings
                    pendingRuleSetLinks = links
                    deepLinkManager.ruleSetLinks = nil
                    showingImportRuleSetsSheet = true
                }
            }
            .sheet(isPresented: $showingDeepLinkAddSheet, onDismiss: { pendingDeepLinkURL = nil }) {
                DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                    AddProxyView(showingManualAddSheet: $showingManualAddSheet, deepLinkURL: pendingDeepLinkURL)
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                ProxyEditorView { configuration in
                    configStore.add(configuration)
                    viewModel.selectIfNone(configuration)
                }
            }
            .sheet(isPresented: $showingImportRuleSetsSheet, onDismiss: { pendingRuleSetLinks = [] }) {
                ImportRuleSetsView(links: pendingRuleSetLinks)
            }
            .alert(String(localized: "Routing Rules Updated"), isPresented: showOrphanedAlert) {
                Button(String(localized: "OK")) {}
            } message: {
                let names = ruleSetStore.orphanedRuleSetNames.joined(separator: ", ")
                Text("The proxy used by the following routing rules was deleted. They have been reset to Default: \(names)")
            }
            // The VK TURN relay cannot show its own captcha — it runs in the
            // tunnel process — so the app presents the page it raised.
            .sheet(item: Binding(
                get: { captchaModel.captchaURL.map(IdentifiedURL.init) },
                set: { if $0 == nil { captchaModel.dismiss() } }
            )) { identified in
                TurnCaptchaView(url: identified.url) { captchaModel.dismiss() }
            }
            .onChange(of: settings.proMode) { _, isPro in
                // The tab it points at is gone; leaving the selection there
                // would show an empty screen.
                if !isPro, selectedTab == .proxies { selectedTab = .home }
            }
            .task {
                captchaModel.start()
                SubscriptionAutoUpdater.shared.refreshOnOpen()
            }
            .onChange(of: scenePhase) { _, phase in
                // iOS grants a VPN app no reliable periodic wake-up, so coming
                // back to the foreground is the moment to catch up.
                if phase == .active {
                    SubscriptionAutoUpdater.shared.refreshOnOpen()
                }
            }
    }

    /// `sheet(item:)` needs identity; a URL alone has none.
    private struct IdentifiedURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @ViewBuilder
    private var tabView: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: $selectedTab) {
                Tab(value: .home) {
                    NavigationStack {
                        HomeView()
                    }
                    .toolbar(.hidden, for: .tabBar)
                } label: {
                    Image("TabIcon")
                }
                
                if settings.proMode {
                    Tab(value: .proxies) {
                        NavigationStack {
                            ProxiesPageView()
                        }
                        .toolbar(.hidden, for: .tabBar)
                        .preferredColorScheme(.dark)
                    } label: {
                        Image(systemName: "network")
                    }
                }
                
                Tab(value: .settings) {
                    NavigationStack {
                        SettingsView()
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        } else {
            TabView(selection: $selectedTab) {
                Tab(value: .home) {
                    NavigationStack {
                        HomeView()
                    }
                    .colorScheme(settings.homeColorScheme == .light ? .light : .dark)
                    .toolbar(.hidden, for: .tabBar)
                } label: {
                    Label("Home", image: "TabIcon")
                }
                
                if settings.proMode {
                    Tab(value: .proxies) {
                        NavigationStack {
                            ProxiesPageView()
                        }
                        .toolbar(.hidden, for: .tabBar)
                        .preferredColorScheme(.dark)
                    } label: {
                        Label("Proxies", systemImage: "network")
                    }
                }
                
                Tab(value: .settings) {
                    NavigationStack {
                        SettingsView()
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .preferredColorScheme(.dark)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}

enum AppTab: Hashable {
    case home, proxies, settings
}
