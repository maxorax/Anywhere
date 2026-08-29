//
//  MainScreenView.swift
//  Turn
//

import SwiftUI

/// The redesigned main screen, shared by both the plain and the pro mode.
///
/// The old layouts are still in ``HomeView`` and still compile — this replaced
/// what they draw, not what they know, and going back is a matter of pointing
/// the body at them again.
struct MainScreenView: View {
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @Binding var showingAddSheet: Bool
    @Binding var showingManualAddSheet: Bool

    @State private var relay = TurnCaptchaModel.shared
    @State private var collapsed: Set<UUID> = []
    @State private var refreshing: UUID?
    @State private var failure: String?
    @State private var showingStats = false

    /// The id standing in for servers added by hand, which have no subscription.
    private static let standaloneGroup = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    groups
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
        }
        // Behind rather than beside: the aura is a 460pt circle, and inside a
        // ZStack it made the whole screen that wide and pushed the header off
        // both edges.
        .background {
            ZStack {
                LinearGradient(colors: MainScreen.backgroundStops, startPoint: .top, endPoint: .bottom)
                MainScreenAura(orbState: orbState, usesRelay: relay.flow.usesRelay)
            }
            .clipped()
            .ignoresSafeArea()
        }
        // The statistics used to take half the main screen outside pro mode.
        // They are one tap away instead, on the line that reports the session.
        .sheet(isPresented: $showingStats) {
            NavigationStack {
                ScrollView {
                    ConnectionStatsView()
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .background {
                    LinearGradient(colors: MainScreen.backgroundStops, startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
                .navigationTitle("Connection")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .alert(String(localized: "Subscription Update Failed"),
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(String(localized: "OK")) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            // No screen title: the tab bar already says which tab this is, and
            // the button is the thing worth looking at first.
            Spacer()
            headerButton(systemImage: "plus") { showingAddSheet = true }
            Menu {
                Button {
                    // Collapsed groups are off screen; testing them would spend
                    // dials the user cannot see.
                    viewModel.testLatencies(for: visibleConfigurations)
                } label: {
                    Label("Test Latency", systemImage: "gauge.with.dots.needle.67percent")
                }
                .disabled(configStore.configurations.isEmpty)

                if !subscriptionStore.subscriptions.isEmpty {
                    Button {
                        for subscription in subscriptionStore.subscriptions { refresh(subscription) }
                    } label: {
                        Label("Update Subscriptions", systemImage: "arrow.clockwise")
                    }
                    .disabled(refreshing != nil)
                }

                Button {
                    showingManualAddSheet = true
                } label: {
                    Label("Add Manually", systemImage: "square.and.pencil")
                }
            } label: {
                headerButtonLabel(systemImage: "ellipsis")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func headerButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { headerButtonLabel(systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    private func headerButtonLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(MainScreen.surface(0.75))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(MainScreen.surface(0.07))
                    .overlay(Circle().stroke(MainScreen.surface(0.09), lineWidth: 1))
            )
    }

    /// Everything on screen — collapsed groups excluded.
    private var visibleConfigurations: [ProxyConfiguration] {
        configStore.configurations.filter { configuration in
            guard let id = configuration.subscriptionId else { return !collapsed.contains(Self.standaloneGroup) }
            return !collapsed.contains(id)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroBlock(
            flow: relay.flow,
            orbState: orbState,
            serverFlag: nil,
            serverName: viewModel.selectedConfiguration?.name,
            connectedSince: viewModel.connectedSince,
            onToggle: { viewModel.toggleVPN() },
            onCaptcha: { relay.present() },
            onStatus: { showingStats = true }
        )
    }

    private var orbState: ConnectionOrb.State {
        switch viewModel.status {
        case .connected: .on
        case .connecting, .reasserting, .disconnecting: .connecting
        case .disconnected, .invalid: .off
        }
    }

    // MARK: Groups

    @ViewBuilder
    private var groups: some View {
        ForEach(subscriptionStore.subscriptions) { subscription in
            ServerGroupCard(
                title: subscription.name,
                configurations: configStore.configurations(for: subscription),
                selectedID: viewModel.selectedConfiguration?.id,
                latencies: viewModel.latencyResults,
                isRefreshing: refreshing == subscription.id,
                isTestingLatency: isTestingLatency(configStore.configurations(for: subscription)),
                isExpanded: expansion(for: subscription.id),
                onSelect: { viewModel.selectedConfiguration = $0 },
                onRefresh: { refresh(subscription) },
                onTestLatency: { viewModel.testLatencies(for: configStore.configurations(for: subscription)) }
            )
        }

        let standalone = configStore.configurations.filter { $0.subscriptionId == nil }
        if !standalone.isEmpty {
            ServerGroupCard(
                title: String(localized: "Added by Hand"),
                configurations: standalone,
                selectedID: viewModel.selectedConfiguration?.id,
                latencies: viewModel.latencyResults,
                isRefreshing: false,
                isTestingLatency: isTestingLatency(standalone),
                isExpanded: expansion(for: Self.standaloneGroup),
                onSelect: { viewModel.selectedConfiguration = $0 },
                onRefresh: nil,
                onTestLatency: { viewModel.testLatencies(for: standalone) }
            )
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            }
        )
    }

    private func isTestingLatency(_ configurations: [ProxyConfiguration]) -> Bool {
        configurations.contains { viewModel.latencyResults[$0.id] == .testing }
    }

    private func refresh(_ subscription: Subscription) {
        guard refreshing == nil else { return }
        refreshing = subscription.id
        Task {
            do {
                try await subscriptionStore.refresh(subscription)
            } catch {
                failure = error.localizedDescription
            }
            refreshing = nil
        }
    }
}
