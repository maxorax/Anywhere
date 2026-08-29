//
//  MainScreenTabBar.swift
//  Turn
//

import SwiftUI

/// The bottom bar, drawn rather than inherited.
///
/// The system's own bar is a light floating capsule of icons, which reads as
/// borrowed from another app on top of this screen. This is the handoff's
/// version: two words in a dark segment, sitting on a gradient that lets the
/// list fade out under it.
struct MainScreenTabBar: View {
    @Binding var selection: AppTab
    /// Pro mode keeps a third tab for managing proxies.
    let showsProxies: Bool

    private var tabs: [(tab: AppTab, title: String)] {
        var tabs: [(AppTab, String)] = [(.home, String(localized: "Servers"))]
        if showsProxies { tabs.append((.proxies, String(localized: "Proxies"))) }
        tabs.append((.settings, String(localized: "Settings")))
        return tabs
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { entry in
                pill(entry.tab, title: entry.title)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: MainScreen.tabBarRadius)
                .fill(MainScreen.surface(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: MainScreen.tabBarRadius)
                        .stroke(MainScreen.surface(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background {
            LinearGradient(
                stops: [
                    .init(color: MainScreen.backgroundStops[2].opacity(0), location: 0),
                    .init(color: MainScreen.backgroundStops[2].opacity(0.92), location: 0.26),
                    .init(color: MainScreen.backgroundStops[2], location: 0.42),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func pill(_ tab: AppTab, title: String) -> some View {
        let active = selection == tab
        return Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? .white : MainScreen.surface(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: MainScreen.tabPillRadius)
                    .fill(active ? MainScreen.surface(0.11) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: MainScreen.tabPillRadius))
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { selection = tab }
            }
    }
}
