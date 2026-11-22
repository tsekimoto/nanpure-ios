import Foundation

// Compile this executable with the same policy source that the app target uses:
// swiftc 'src/ナンプレ/WebContentPolicy.swift' tests/main.swift -o /tmp/nanpure-policy-tests
let policy = WebContentPolicy(allowedHosts: ["tsekimoto.github.io"])
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("Web content policy failed: \(name)") }
    checks += 1
}

let trustedURLCases = [
    "https://tsekimoto.github.io/nanpure-pwa/",
    "https://TSEKIMOTO.GITHUB.IO:443/nanpure-pwa/privacy.html?from=game#privacy"
]
for text in trustedURLCases {
    expect(policy.trustsURL(URL(string: text)), "HTTPS exact origin: \(text)")
}
let untrustedURLCases = [
    "http://tsekimoto.github.io/nanpure-pwa/",
    "https://tsekimoto.github.io:80/",
    "https://tsekimoto.github.io:0/",
    "https://tsekimoto.github.io:444/",
    "https://tsekimoto.github.io.evil.example/",
    "https://evil-tsekimoto.github.io/",
    "https://sub.tsekimoto.github.io/",
    "https://tsekimoto.github.io./",
    "https://user@tsekimoto.github.io/",
    "https://tsekimoto.github.io@evil.example/",
    "https://evil.example/?next=https://tsekimoto.github.io/",
    "file:///nanpure-pwa/index.html",
    "javascript:alert(1)",
    "data:text/html,game",
    "about:blank"
]
for text in untrustedURLCases {
    expect(!policy.trustsURL(URL(string: text)), "untrusted URL: \(text)")
}
expect(!policy.trustsURL(nil), "missing URL")

expect(policy.trustsMainFrame(scheme: "https", host: "tsekimoto.github.io", port: 0, isMainFrame: true), "default WK security-origin port")
expect(policy.trustsMainFrame(scheme: "https", host: "tsekimoto.github.io", port: 443, isMainFrame: true), "explicit HTTPS security-origin port")
expect(!policy.trustsMainFrame(scheme: "https", host: "tsekimoto.github.io", port: 443, isMainFrame: false), "same-origin iframe cannot call native bridge")
expect(!policy.trustsMainFrame(scheme: "http", host: "tsekimoto.github.io", port: 80, isMainFrame: true), "HTTP cannot call native bridge")
expect(!policy.trustsMainFrame(scheme: "https", host: "tsekimoto.github.io.evil.example", port: 443, isMainFrame: true), "lookalike host cannot call native bridge")
expect(!policy.trustsMainFrame(scheme: "https", host: "tsekimoto.github.io", port: 444, isMainFrame: true), "different port cannot call native bridge")

func decision(_ text: String?, mainFrame: Bool = true, trustedSource: Bool = true,
              userActivated: Bool = false, download: Bool = false) -> WebContentPolicy.Navigation {
    policy.navigation(to: text.flatMap { URL(string: $0) }, targetIsMainFrame: mainFrame,
                      trustedSource: trustedSource, userActivated: userActivated, shouldDownload: download)
}

let game = "https://tsekimoto.github.io/nanpure-pwa/"
let blob = "blob:https://tsekimoto.github.io/8d6446b1-7677-4e96-9ca9-1dc909cc4f87"
expect(decision(game, trustedSource: false) == .allow, "initial native navigation can load game")
expect(decision(game, mainFrame: false) == .cancel, "game does not create privileged iframes")
expect(decision(game, download: true) == .download, "trusted main-frame download")
expect(decision(game, trustedSource: false, download: true) == .cancel, "untrusted source cannot download")
expect(decision(blob) == .download, "trusted game blob download")
expect(decision(blob, mainFrame: false) == .cancel, "iframe cannot download game blob")
expect(decision(blob, trustedSource: false) == .cancel, "untrusted source cannot download blob")
expect(decision("blob:https://evil.example/123") == .cancel, "external blob is rejected")
expect(decision("blob:null/123") == .cancel, "opaque blob is rejected")
expect(decision("blob:https://tsekimoto.github.io:444/123") == .cancel, "blob on a different port is rejected")
expect(decision("https://example.com", userActivated: true) == .openExternally, "user external link opens outside game")
expect(decision("https://example.com") == .cancel, "automatic external navigation cannot escape origin")
expect(decision("https://example.com", mainFrame: false, userActivated: true) == .cancel, "iframe cannot open external UI")
expect(decision("https://example.com", trustedSource: false, userActivated: true) == .cancel, "untrusted source cannot open external UI")
expect(decision("https://tsekimoto.github.io.evil.example/", userActivated: true) == .openExternally, "lookalike host never loads in game")
expect(decision("http://tsekimoto.github.io/", userActivated: true) == .openExternally, "HTTP link stays outside privileged game")
expect(decision("https://user:pass@example.com/", userActivated: true) == .cancel, "credentials in external URL rejected")
expect(decision("tel:123", userActivated: true) == .openExternally, "user telephone link")
expect(decision("mailto:test@example.com", userActivated: true) == .openExternally, "user mail link")
expect(decision("tel:123") == .cancel, "automatic telephone link rejected")
expect(decision("customapp://open", userActivated: true) == .cancel, "unapproved custom schemes rejected")
expect(decision("javascript:alert(1)", userActivated: true) == .cancel, "script navigation rejected")
expect(decision("about:blank") == .cancel, "blank top-level navigation cannot inherit bridge")
expect(decision(nil) == .cancel, "missing navigation URL")

print("Web content policy: \(checks) checks passed")
