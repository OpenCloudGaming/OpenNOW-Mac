import SwiftUI
import WebKit

/// Renders NVIDIA's in-app feedback survey inside OpenNOW.
///
/// The survey is a normal web app at `gx-surveys.nvidia.com`; its answers are submitted by that page
/// to NVIDIA. This view only hosts it, so no feedback text or identity is posted by OpenNOW itself.
struct OPNFeedbackSurveyView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.customUserAgent = Self.userAgent
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    /// The survey's front end is a Chromium-era web app; a plain Safari user agent keeps it off its
    /// unsupported-browser path.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
