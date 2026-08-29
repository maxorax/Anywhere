//
//  HomeView.swift
//  Turn
//
//  Created by NodePassProject on 3/1/26.
//

import SwiftUI
import NetworkExtension

struct HomeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(SubscriptionStore.self) private var subscriptionStore

    private let coordinator = ProxyRowCoordinator.shared
    
    private static let horizontalPadding: CGFloat = 20
    private static let paneSpacing: CGFloat = 20
    private static let minControlPaneWidth: CGFloat = 320
    private static let maxControlPaneWidth: CGFloat = 500

    @Namespace private var namespace

    @State private var containerSize = CGSize.zero
    
    @State private var connectionEffectsEnabled = false
    
    @State private var showingAddSheet = false
    @State private var showingManualAddSheet = false
    @State private var configurationToEdit: ProxyConfiguration?
    @State private var collapsedSubscriptions: Set<UUID> = []
    @State private var updatingSubscription: Subscription?
    @State private var subscriptionErrorMessage = ""
    @State private var showingSubscriptionError = false

    private var isLoading: Bool { !configStore.isLoaded }

    private var isConnected: Bool {
        viewModel.vpnStatus == .connected
    }

    private var isTransitioning: Bool { viewModel.vpnStatus.isTransitioning }

    var body: some View {
        ZStack {
            BackgroundGradient(isConnected: isConnected)
                .ignoresSafeArea()

            // The redesigned screen, and the same one in both modes. The three
            // layouts below are left intact rather than deleted — they are the
            // way back, and pro mode will want parts of them again.
            Group {
                MainScreenView(
                    showingAddSheet: $showingAddSheet,
                    showingManualAddSheet: $showingManualAddSheet
                )
            }
            .animation(connectionEffectsEnabled ? Animation.bouncy : nil, value: isConnected)
            .sensoryFeedback(trigger: isConnected) { _, _ in
                guard connectionEffectsEnabled else { return nil }
                return .impact
            }
        }
        .colorScheme(settings.homeColorScheme.colorSceme)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            containerSize = size
        }
        .sheet(isPresented: $showingAddSheet) {
            DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                AddProxyView(showingManualAddSheet: $showingManualAddSheet)
            }
        }
        .sheet(isPresented: $showingManualAddSheet) {
            ProxyEditorView { configuration in
                configStore.add(configuration); viewModel.selectIfNone(configuration)
            }
        }
        .sheet(item: $configurationToEdit) { configuration in
            ProxyEditorView(configuration: configuration) { updated in
                configStore.update(updated)
            }
        }
        // The redesigned screen draws its own header with the same two buttons;
        // leaving the navigation bar on top of it showed both.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            // Pro mode keeps proxy management on its own tab; without it this
            // is the only way to add one.
            if !settings.proMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button {
                            // Collapsed subscriptions are off screen; testing
                            // them would spend dials the user cannot see.
                            let visible = configStore.configurations.filter { configuration in
                                guard let id = configuration.subscriptionId else { return true }
                                return !collapsedSubscriptions.contains(id)
                            }
                            viewModel.testLatencies(for: visible)
                        } label: {
                            Label("Test Latency", systemImage: "gauge.with.dots.needle.67percent")
                        }
                        .disabled(configStore.configurations.isEmpty)

                        if !subscriptionStore.subscriptions.isEmpty {
                            Button {
                                updateAllSubscriptions()
                            } label: {
                                Label("Update Subscriptions", systemImage: "arrow.clockwise")
                            }
                            .disabled(updatingSubscription != nil)
                        }
                    }
                }
            }
        }
        .alert("Subscription Update Failed", isPresented: $showingSubscriptionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: subscriptionErrorMessage)
        }
        .alert("VPN Error", isPresented: Binding(
            get: { viewModel.startError != nil },
            set: { if !$0 { viewModel.startError = nil } }
        )) {
            Button("OK") { viewModel.startError = nil }
        } message: {
            Text(viewModel.startError ?? "")
        }
        .onChange(of: viewModel.isManagerReady, initial: true) { _, ready in
            guard ready, !connectionEffectsEnabled else { return }
            Task { @MainActor in connectionEffectsEnabled = true }
        }
    }

    // MARK: - Layouts

    private var contentWidth: CGFloat {
        containerSize.width - 2 * Self.horizontalPadding
    }

    private static func allowsSideBySide(contentWidth: CGFloat) -> Bool {
        StatCardSize.columnCount(fitting: contentWidth) > ConnectionStatsView.maxColumnCount
    }

    private var stackedLayout: some View {
        DetailRevealScrollView(revealsDetail: isConnected) {
            connectionControls
                .padding(.horizontal, Self.horizontalPadding)
        } detail: {
            ConnectionStatsView()
                .padding(.top, 16)
                .padding(.horizontal, Self.horizontalPadding)
        }
    }
    
    private var sideBySideLayout: some View {
        // Give the stats pane what a fully grown grid needs, but never squeeze
        // the controls pane below its minimum width.
        let detailWidth = min(
            StatCardSize.gridWidth(
                columns: ConnectionStatsView.maxColumnCount,
                unitLength: StatCardSize.maxUnitLength
            ),
            contentWidth - Self.minControlPaneWidth - Self.paneSpacing
        )
        return HStack(spacing: Self.paneSpacing) {
            ScrollView {
                connectionControls
                    .frame(maxWidth: .infinity, minHeight: containerSize.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)

            ScrollView {
                ConnectionStatsView()
                    .padding(.vertical, 16)
                    .frame(minHeight: containerSize.height)
            }
            .frame(width: detailWidth)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .frame(maxWidth: Self.maxControlPaneWidth + Self.paneSpacing + detailWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.horizontalPadding)
    }

    /// The screen outside pro mode: connect control on top, servers below.
    ///
    /// No statistics page here, which means no paging behaviour to fight — the
    /// list is a plain `List` and keeps its swipe actions and collapsible
    /// subscription sections.
    private var simpleLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                powerButton
                statusLabel
            }
            .padding(.top, 8)
            .padding(.bottom, 20)

            serverList
        }
    }

    @ViewBuilder
    private var serverList: some View {
        if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else if configStore.configurations.isEmpty {
            Spacer()
            AddConfigurationCapsule { showingAddSheet = true }
                .frame(maxWidth: Self.maxControlPaneWidth)
                .padding(.horizontal, Self.horizontalPadding)
            Spacer()
        } else {
            List {
                Section {
                    ForEach(standaloneItems) { item in
                        proxyRow(item, editingDisabled: false)
                    }
                }
                ForEach(subscriptionStore.subscriptions) { subscription in
                    let editingDisabled = SubscriptionDomainHelper.shouldDisableProxyEditing(for: subscription.url)
                    Section {
                        DisclosureGroup(isExpanded: expansionBinding(for: subscription)) {
                            ForEach(items(for: subscription)) { item in
                                proxyRow(item, editingDisabled: editingDisabled)
                            }
                        } label: {
                            subscriptionHeader(subscription)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func subscriptionHeader(_ subscription: Subscription) -> some View {
        HStack(spacing: 14) {
            Text(subscription.name)
                .font(.body.weight(.medium))
            if updatingSubscription?.id == subscription.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    updateSubscription(subscription)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            Button {
                viewModel.testLatencies(for: configStore.configurations(for: subscription))
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(.borderless)
            .disabled(isTestingLatency(subscription))
            .foregroundStyle(isTestingLatency(subscription) ? Color.secondary : Color.green)
        }
    }

    private func isTestingLatency(_ subscription: Subscription) -> Bool {
        configStore.configurations(for: subscription).contains { configuration in
            if case .testing = viewModel.latencyResults[configuration.id] { return true }
            return false
        }
    }

    private func updateSubscription(_ subscription: Subscription) {
        guard updatingSubscription == nil else { return }
        updatingSubscription = subscription
        Task {
            do {
                try await subscriptionStore.refresh(subscription)
            } catch {
                subscriptionErrorMessage = error.localizedDescription
                showingSubscriptionError = true
            }
            updatingSubscription = nil
        }
    }

    private func updateAllSubscriptions() {
        guard updatingSubscription == nil else { return }
        Task {
            var failures: [String] = []
            for id in subscriptionStore.subscriptions.map(\.id) {
                guard let subscription = subscriptionStore.subscriptions.first(where: { $0.id == id }) else { continue }
                updatingSubscription = subscription
                do {
                    try await subscriptionStore.refresh(subscription)
                } catch {
                    failures.append("\(subscription.name): \(error.localizedDescription)")
                }
            }
            updatingSubscription = nil
            if !failures.isEmpty {
                subscriptionErrorMessage = failures.joined(separator: "\n")
                showingSubscriptionError = true
            }
        }
    }

    private var standaloneItems: [ProxyListItem] {
        coordinator.models.filter { $0.subscriptionId == nil }
    }

    private func items(for subscription: Subscription) -> [ProxyListItem] {
        coordinator.models.filter { $0.subscriptionId == subscription.id }
    }

    private func expansionBinding(for subscription: Subscription) -> Binding<Bool> {
        Binding(
            get: { !collapsedSubscriptions.contains(subscription.id) },
            set: { expanded in
                if expanded {
                    collapsedSubscriptions.remove(subscription.id)
                } else {
                    collapsedSubscriptions.insert(subscription.id)
                }
            }
        )
    }

    private func configuration(_ id: UUID) -> ProxyConfiguration? {
        configStore.configurations.first { $0.id == id }
    }

    private func proxyRow(_ item: ProxyListItem, editingDisabled: Bool) -> some View {
        ProxyRowView(
            item: item,
            editingDisabled: editingDisabled,
            onSelect: { if let c = configuration(item.id) { viewModel.selectedConfiguration = c } },
            onTestLatency: { if let c = configuration(item.id) { viewModel.testLatency(for: c) } },
            onCopyLink: { if let c = configuration(item.id) { UIPasteboard.general.string = c.toURL() } },
            onEdit: { configurationToEdit = configuration(item.id) },
            onDelete: { if let c = configuration(item.id) { configStore.delete(c) } }
        )
    }

    private var connectionControls: some View {
        VStack(spacing: 80) {
            VStack(spacing: 20) {
                powerButton
                    .matchedGeometryEffect(id: "powerButton", in: namespace)
                statusLabel
                    .matchedGeometryEffect(id: "statusLabel", in: namespace)
            }
            configurationCard
                .matchedGeometryEffect(id: "configurationCard", in: namespace)
        }
    }

    private var powerButton: some View {
        PowerButton(
            isConnected: isConnected,
            isTransitioning: isTransitioning,
            isLoading: isLoading,
            isDisabled: isLoading
                || (viewModel.isButtonDisabled(hasConfigurations: configStore.hasConfigurations)
                    && configStore.hasConfigurations),
            animatesChanges: connectionEffectsEnabled
        ) {
            guard !isLoading else { return }
            if configStore.hasConfigurations {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    viewModel.toggleVPN()
                }
            } else {
                showingAddSheet = true
            }
        }
    }

    private var configurationCard: some View {
        ConfigurationCapsule(isConnected: isConnected, showingAddSheet: $showingAddSheet)
            .frame(maxWidth: Self.maxControlPaneWidth)
    }
    
    private var statusLabel: some View {
        VStack(spacing: 4) {
            Text(viewModel.statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
            // Counting up from the system's own connect time, so the reading
            // stays honest across an app relaunch — and answers the one question
            // a bare "Connected" leaves open: is traffic actually flowing yet.
            if isConnected, let connectedSince = viewModel.connectedSince {
                Text(connectedSince, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.connectedSince)
    }
}

// MARK: - Background

private struct BackgroundGradient: View {
    @Environment(AppSettings.self) private var settings

    let isConnected: Bool

    var body: some View {
        if isConnected {
            LinearGradient(
                colors: [
                    color(settings.connectedBackgroundStartData, default: .connectedBackgroundStart),
                    color(settings.connectedBackgroundEndData, default: .connectedBackgroundEnd),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .transition(.blurReplace)
        } else {
            LinearGradient(
                colors: [
                    color(settings.disconnectedBackgroundStartData, default: .disconnectedBackgroundStart),
                    color(settings.disconnectedBackgroundEndData, default: .disconnectedBackgroundEnd),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .transition(.blurReplace)
        }
    }

    private func color(_ data: Data?, default fallback: Color) -> Color {
        data.flatMap(Color.init(archivedData:)) ?? fallback
    }
}

// MARK: - Power Button

private struct PowerButton: View {
    private static let circleDiameter: CGFloat = 140

    let isConnected: Bool
    let isTransitioning: Bool
    let isLoading: Bool
    let isDisabled: Bool
    let animatesChanges: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if #available(iOS 27.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.regular, in: .circle)
                } else if #available(iOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: Self.circleDiameter)
                        .glassEffect(.clear, in: .circle)
                } else {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: Self.circleDiameter)
                        .shadow(color: isConnected ? .cyan.opacity(0.4) : .black.opacity(0.08), radius: isConnected ? 24 : 8)
                }
                if isTransitioning || isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .light))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(animatesChanges ? Animation.easeInOut(duration: 0.6) : nil, value: isConnected)
    }
}

// MARK: - Configuration Capsule

private struct ConfigurationCapsule: View {
    @Environment(VPNViewModel.self) private var viewModel
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(SubscriptionStore.self) private var subscriptionStore

    let isConnected: Bool
    @Binding var showingAddSheet: Bool

    var body: some View {
        if let configuration = viewModel.selectedConfiguration {
            selectedCapsule(configuration)
        } else if configStore.isLoaded {
            emptyCapsule
        } else {
            loadingCapsule
        }
    }

    private func select(id: UUID) {
        if let chain = chainStore.chains.first(where: { $0.id == id }) {
            viewModel.selectChain(chain, configurations: configStore.configurations)
        } else if let configuration = configStore.configurations.first(where: { $0.id == id }) {
            viewModel.selectedConfiguration = configuration
        }
    }

    @ViewBuilder
    private func selectedCapsule(_ configuration: ProxyConfiguration) -> some View {
        Menu {
            ForEach(configStore.standalonePickerItems) { item in
                Button(item.name) { select(id: item.id) }
            }
            if !chainStore.pickerItems.isEmpty {
                Section {
                    ForEach(chainStore.pickerItems) { item in
                        Button(item.name) { select(id: item.id) }
                    }
                } header: {
                    Text("Chains")
                }
            }
            ForEach(subscriptionStore.pickerSections) { section in
                Section {
                    ForEach(section.items) { item in
                        Button(item.name) { select(id: item.id) }
                    }
                } header: {
                    Text(section.header ?? "")
                }
            }
            Button {
                showingAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
        } label: {
            ProminentCapsule {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(width: 24)
                    Text(configuration.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyCapsule: some View {
        AddConfigurationCapsule { showingAddSheet = true }
    }
    
    private var loadingCapsule: some View {
        ProminentCapsule {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// The empty-state call to action.
///
/// Shared by both home layouts: the plain one shows it in place of the server
/// list, pro mode in place of the configuration capsule. One definition so the
/// two cannot drift apart.
private struct AddConfigurationCapsule: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProminentCapsule {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Add a Configuration")
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ProminentCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 27.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        } else if #available(iOS 26.0, *) {
            content
                .padding(16)
                .contentShape(Capsule())
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .padding(16)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(.white.opacity(0.2))
                )
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connected") {
    let settings = AppSettings.shared
    
    let viewModel = VPNViewModel()
    viewModel.selectedConfiguration = ProxyConfiguration(
        name: "🇺🇸 Los Angeles",
        serverAddress: "203.0.113.10",
        serverPort: 443,
        outbound: .socks5(username: nil, password: nil)
    )
    viewModel.vpnStatus = .connected

    return HomeView()
        .environment(settings)
        .environment(viewModel)
        .environment(ConfigurationStore.shared)
        .environment(ChainStore.shared)
        .environment(SubscriptionStore.shared)
        .environment(ConnectionStatsModel.previewSeeded())
        .colorScheme(.dark)
}
#endif
