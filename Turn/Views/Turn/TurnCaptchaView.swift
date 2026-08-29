//
//  TurnCaptchaView.swift
//  Turn
//

import SwiftUI
import WebKit

/// Shows the captcha page the VK TURN core raised on its local HTTP server.
///
/// There is no token hand-back: the core's own server collects whatever the user
/// solves and carries on. The sheet closes itself once the relay leaves the
/// captcha phase.
struct TurnCaptchaView: View {
    let url: URL
    /// Closing only takes the sheet away — deliberately not the tunnel.
    ///
    /// The sheet lingers for a moment after a captcha is solved, and people
    /// close it themselves rather than wait; tearing the connection down there
    /// would undo the captcha they had just got through. Abandoning the attempt
    /// is the power button's job, and it stays live while connecting.
    var onClose: () -> Void

    @State private var reloadToken = 0
    /// Height of the captcha page itself, measured as it loads. VK's page is a
    /// small card; a full-screen sheet around it looked like something had gone
    /// wrong.
    @State private var contentHeight: CGFloat = Self.initialHeight

    private static let initialHeight: CGFloat = 420
    private static let minimumHeight: CGFloat = 260
    /// Room left for the sheet's own top inset when the page is a tall one.
    private static let screenInset: CGFloat = 140
    /// Navigation bar plus the padding the sheet adds under it.
    private static let chromeHeight: CGFloat = 56

    var body: some View {
        NavigationStack {
            CaptchaWebView(url: url, reloadToken: reloadToken) { measured in
                let ceiling = max(Self.minimumHeight, Self.windowHeight - Self.screenInset)
                let fitted = min(max(measured + Self.chromeHeight, Self.minimumHeight), ceiling)
                guard abs(fitted - contentHeight) > 1 else { return }
                withAnimation(.easeInOut(duration: 0.25)) { contentHeight = fitted }
            }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("VK Captcha")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(MainScreen.backgroundStops[2], for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .tint(MainScreen.accent)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { onClose() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            reloadToken += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
        .interactiveDismissDisabled(true)
        // The page inside is VK's and stays white; everything around it belongs
        // to this app.
        .preferredColorScheme(.dark)
        .presentationBackground(MainScreen.backgroundStops[2])
        // The fitted height first, with the full one still available for a page
        // that needs scrolling or a captcha that grows after it loads.
        .presentationDetents([.height(contentHeight), .large])
        .presentationDragIndicator(.hidden)
    }

    private static var windowHeight: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    /// Called with the page's own content height whenever it changes — the
    /// captcha widget arrives after the page does, so one measurement on load
    /// would be the wrong one.
    let onHeight: @MainActor @Sendable (CGFloat) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = false
        // The page is shown whole in a sheet its own size, so iOS must not add
        // insets of its own — and VK's page scrolls itself down to the widget
        // as it loads, which cut the heading off the top.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        context.coordinator.watchHeight(of: webView, report: onHeight)
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastToken = 0
        private var observation: NSKeyValueObservation?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setContentOffset(.zero, animated: false)
        }

        func watchHeight(of webView: WKWebView, report: @escaping @MainActor @Sendable (CGFloat) -> Void) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { scrollView, _ in
                let height = scrollView.contentSize.height
                guard height > 1 else { return }
                Task { @MainActor in report(height) }
            }
        }
    }
}
