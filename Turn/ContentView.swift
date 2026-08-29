//
//  ContentView.swift
//  Turn
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI

struct ContentView: View {
    @State private var deepLinkManager = DeepLinkManager()
    @State private var onboardingCompleted = AWCore.getOnboardingCompleted()

    var body: some View {
        Group {
            if onboardingCompleted {
                MainTabView()
            } else {
                OnboardingView(completed: $onboardingCompleted)
            }
        }
            .onOpenURL { url in
                deepLinkManager.handle(url: url)
            }
            .environment(AppSettings.shared)
            .environment(VPNViewModel.shared)
            .environment(ConfigurationStore.shared)
            .environment(SubscriptionStore.shared)
            .environment(ChainStore.shared)
            .environment(ConnectionStatsModel.shared)
            .environment(RequestsModel.shared)
            .environment(LogsModel.shared)
            .environment(RoutingRuleSetStore.shared)
            .environment(CertificateStore.shared)
            .environment(MITMRuleSetStore.shared)
            .environment(MITMCertificateController.shared)
            .environment(deepLinkManager)
            .task {
                // The onboarding used to make this request on its way out: on a
                // Chinese device iOS only raises the local-network prompt once
                // something actually reaches for the network, and asking here
                // keeps that prompt in front of the user rather than mid-connect.
                guard DeviceCensorship.isChinaDevice,
                      let url = URL(string: "https://captive.apple.com")
                else { return }
                _ = try? await URLSession.shared.data(from: url)
            }
    }
}
