import SwiftUI
import UIKit
import WebKit

/// Thin SwiftUI wrapper around WKWebView that loads the chrome-less embed
/// viewer hosted on scan-api (`/embed/scan/{rfqId}`). Used for the iOS
/// Project Detail screen's Bird's Eye tab.
struct EmbedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let pref = WKWebpagePreferences()
        pref.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pref

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        // Let the 3D canvas capture touches without the scroll view intercepting.
        webView.scrollView.panGestureRecognizer.isEnabled = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
