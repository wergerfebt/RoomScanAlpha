import SwiftUI
import UIKit
import WebKit

/// Contractor workspace — loaded via WebView against roomscanalpha.com so
/// iOS inherits the web implementation (Jobs, Gallery, Team, Services,
/// Settings, Inbox). The web page will prompt the user to sign in the
/// first time; Firebase auth state persists in WKWebView storage after.
struct WorkspaceView: View {
    let orgName: String?
    let onClose: () -> Void

    private let url = URL(string: "https://roomscanalpha.com/org?tab=jobs")!

    var body: some View {
        NavigationStack {
            ZStack {
                Color(QTheme.ink).ignoresSafeArea()
                WorkspaceWebView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(orgName ?? "Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onClose)
                        .foregroundStyle(QTheme.ink)
                }
            }
        }
        .tint(QTheme.primary)
    }
}

/// Web view tuned for the contractor workspace — allows normal scroll,
/// inline media, and JavaScript. Distinct from the BEV-focused
/// EmbedWebView which suppresses scrolling.
private struct WorkspaceWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let pref = WKWebpagePreferences()
        pref.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pref

        // Persistent data store so Firebase auth cookies survive across
        // launches. Without this the user would sign in every time.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url { webView.load(URLRequest(url: url)) }
    }
}
