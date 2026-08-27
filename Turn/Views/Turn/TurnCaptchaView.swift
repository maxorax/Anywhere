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
    /// Closing gives up on the connection: the caller stops the tunnel, since a
    /// relay parked on an unsolved captcha would otherwise keep spinning behind
    /// a dismissed sheet.
    var onClose: () -> Void

    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            CaptchaWebView(url: url, reloadToken: reloadToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("VK Captcha")
                .navigationBarTitleDisplayMode(.inline)
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
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken else { return }
        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastToken = 0
    }
}
