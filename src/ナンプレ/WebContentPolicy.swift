import Foundation

// The game web view remains restricted to its HTTPS origin without opting every
// WKWebView in the app (including Google Mobile Ads) into App-Bound Domains.
struct WebContentPolicy {
    enum Navigation: Equatable {
        case allow, download, openExternally, cancel
    }

    private let allowedHosts: Set<String>

    init(allowedHosts: [String]) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
    }

    func trustsOrigin(scheme: String, host: String, port: Int) -> Bool {
        scheme.lowercased() == "https"
            && allowedHosts.contains(host.lowercased())
            && (port == 0 || port == 443)
    }

    func trustsURL(_ url: URL?) -> Bool {
        guard let url, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let scheme = url.scheme, let host = url.host else { return false }
        return trustsOrigin(scheme: scheme, host: host, port: url.port ?? 443)
    }

    func trustsMainFrame(scheme: String, host: String, port: Int, isMainFrame: Bool) -> Bool {
        isMainFrame && trustsOrigin(scheme: scheme, host: host, port: port)
    }

    func trustsBlobURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "blob" else { return false }
        return trustsURL(URL(string: String(url.absoluteString.dropFirst(5))))
    }

    func navigation(to url: URL?, targetIsMainFrame: Bool, trustedSource: Bool,
                    userActivated: Bool, shouldDownload: Bool) -> Navigation {
        // The game does not use frames. Do not let a frame become a second
        // privileged entry point for printing, downloads or rewarded ads.
        guard targetIsMainFrame, let url else { return .cancel }
        if trustsURL(url) {
            return shouldDownload ? (trustedSource ? .download : .cancel) : .allow
        }
        if trustsBlobURL(url) {
            return trustedSource ? .download : .cancel
        }
        guard trustedSource, userActivated else { return .cancel }
        switch url.scheme?.lowercased() {
        case "https", "http":
            return url.host == nil || url.user != nil || url.password != nil ? .cancel : .openExternally
        case "tel", "mailto":
            return .openExternally
        default:
            return .cancel
        }
    }
}
