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
    @State private var renaming: Subscription?
    @State private var renamedTo = ""
    /// Shown for a moment after a refresh, so a successful one is not silent.
    @State private var note: String?

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
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MainScreen.rowTitle)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(MainScreen.surface(0.11))
                            .overlay(Capsule().stroke(MainScreen.surface(0.09), lineWidth: 1))
                    )
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: note)
        .alert(String(localized: "Rename"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField(String(localized: "Name"), text: $renamedTo)
            Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
            Button(String(localized: "Save")) {
                if let renaming, !renamedTo.isEmpty {
                    subscriptionStore.rename(renaming, to: renamedTo)
                }
                renaming = nil
            }
        }
        .onChange(of: renaming?.id) { _, _ in
            renamedTo = renaming?.name ?? ""
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
            caption: caption,
            serverFlag: nil,
            serverName: viewModel.selectedConfiguration?.name,
            connectedSince: viewModel.connectedSince,
            onToggle: { viewModel.toggleVPN() },
            onCaptcha: { relay.present() },
            onStatus: { showingStats = true }
        )
    }

    /// The words under the button. Disconnecting has its own, rather than
    /// borrowing the ones for connecting.
    private var caption: String {
        switch viewModel.status {
        case .disconnecting: String(localized: "Disconnecting…")
        case .connecting, .reasserting: String(localized: "Connecting…")
        case .connected, .disconnected, .invalid: String(localized: "Tap to connect")
        }
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
                traffic: Self.traffic(of: subscription),
                expiry: Self.expiry(of: subscription),
                expired: Self.isExpired(subscription),
                configurations: configStore.configurations(for: subscription),
                selectedID: viewModel.selectedConfiguration?.id,
                latencies: viewModel.latencyResults,
                isRefreshing: refreshing == subscription.id,
                isTestingLatency: isTestingLatency(configStore.configurations(for: subscription)),
                isExpanded: expansion(for: subscription.id),
                onSelect: { viewModel.selectedConfiguration = $0 },
                onRefresh: { refresh(subscription) },
                onTestLatency: { viewModel.testLatencies(for: configStore.configurations(for: subscription)) },
                onRename: { renaming = subscription },
                onDelete: { subscriptionStore.delete(subscription, configurationStore: configStore) }
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

    /// Spent over the allowance. A panel that sets no limit sends no total, and
    /// then there is nothing to divide by — the infinity says so.
    private static func traffic(of subscription: Subscription) -> String? {
        let used = (subscription.upload ?? 0) + (subscription.download ?? 0)
        if let total = subscription.total, total > 0 {
            return "\(format(used)) / \(format(total))"
        }
        return used > 0 ? "\(format(used)) / ∞" : nil
    }

    private static func expiry(of subscription: Subscription) -> String? {
        guard let expire = validExpiry(of: subscription) else { return nil }
        if expire < .now { return String(localized: "Expired") }
        return String(localized: "until \(expire.formatted(.dateTime.day().month().year()))")
    }

    private static func isExpired(_ subscription: Subscription) -> Bool {
        guard let expire = validExpiry(of: subscription) else { return false }
        return expire < .now
    }

    /// A subscription that never runs out arrives as `expire=0`, which is 1970
    /// once it becomes a date. The fetcher drops it now, but subscriptions
    /// imported before that still carry it, so anything from before the app
    /// could plausibly exist is read as "no expiry" rather than long expired.
    private static func validExpiry(of subscription: Subscription) -> Date? {
        guard let expire = subscription.expire,
              expire.timeIntervalSince1970 > 946_684_800  // 2000-01-01
        else { return nil }
        return expire
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
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
                // Announced rather than silent: a refresh that says nothing is
                // indistinguishable from a button that does nothing, and success
                // is the case that happens most.
                show(String(localized: "Subscription updated"))
            } catch {
                failure = error.localizedDescription
            }
            refreshing = nil
        }
    }

    private func show(_ text: String) {
        note = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if note == text { note = nil }
        }
    }
}
