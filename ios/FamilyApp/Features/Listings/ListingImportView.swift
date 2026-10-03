import FamilyCore
import SwiftUI
import WebKit

/// Shows the ad in a real browser view and reads the page the person is looking at. Our servers never fetch the
/// portal (they would be blocked, and a server-side fetcher is an SSRF risk); the portal sees an ordinary visit
/// from the person's own phone, and nothing from this view is kept: the data store is non-persistent.
struct ListingImportView: View {
    let url: URL
    let onImport: (ListingDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reader = PageReader()
    @State private var nothingFound = false

    var body: some View {
        NavigationStack {
            ImportWebView(url: url, reader: reader)
                .safeAreaInset(edge: .top) {
                    Text(nothingFound ? LocalizedStringKey("listings.import.empty") : LocalizedStringKey("listings.import.hint"))
                        .font(.footnote)
                        .foregroundStyle(nothingFound ? .red : .secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
                .navigationTitle("listings.import.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("listings.import.use") { Task { await useThisPage() } }
                            .accessibilityIdentifier("useThisPageButton")
                    }
                }
        }
    }

    private func useThisPage() async {
        let draft = await reader.html().map { ListingPageParser.parse(html: $0) } ?? ListingDraft()
        if draft.isEmpty {
            nothingFound = true
        } else {
            onImport(draft)
            dismiss()
        }
    }
}

@MainActor
final class PageReader {
    fileprivate weak var webView: WKWebView?

    func html() async -> String? {
        try? await webView?.evaluateJavaScript("document.documentElement.outerHTML") as? String
    }
}

private struct ImportWebView: UIViewRepresentable {
    let url: URL
    let reader: PageReader

    func makeCoordinator() -> Coordinator { Coordinator(startHost: url.host() ?? "") }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        reader.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Keeps the person on the portal: only https, and the main page may only move within the same site.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let startSite: String

        init(startHost: String) {
            startSite = Self.site(of: startHost)
        }

        static func site(of host: String) -> String {
            host.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, url.scheme == "https" || url.scheme == "about" else { return .cancel }
            if action.targetFrame?.isMainFrame == true, url.scheme == "https", Self.site(of: url.host() ?? "") != startSite {
                return .cancel
            }
            return .allow
        }
    }
}
