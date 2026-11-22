import Foundation

// Compile this executable with the same policy source that the app target uses:
// swiftc 'src/ナンプレ/WebContentPolicy.swift' 'src/ナンプレ/AdLifecyclePolicy.swift' tests/main.swift -o /tmp/nanpure-policy-tests
let policy = WebContentPolicy(allowedHosts: ["tsekimoto.github.io"])
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("App policy failed: \(name)") }
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

let loadedAt = Date(timeIntervalSince1970: 1_000_000)
var ads = RewardedAdLifecycle()
let firstLoad = ads.beginLoad()!
expect(ads.beginLoad() == nil, "repeated requests share one pending load")
expect(!ads.completeLoad(token: UUID(), succeeded: true, now: loadedAt), "foreign load callback ignored")
expect(ads.completeLoad(token: firstLoad, succeeded: true, now: loadedAt), "current load accepted")
expect(ads.beginLoad() == nil, "loaded ad prevents another prefetch")
expect(ads.hasFreshAd(now: loadedAt.addingTimeInterval(3_599)), "cached ad fresh before one hour")
expect(!ads.hasFreshAd(now: loadedAt.addingTimeInterval(3_600)), "cached ad expires at one hour")
expect(ads.beginPresentation(adID: firstLoad, now: loadedAt.addingTimeInterval(3_600)) == nil, "expired ad cannot present")
expect(ads.expireCache(now: loadedAt.addingTimeInterval(3_600)), "expired ad evicted")

let secondLoad = ads.beginLoad()!
expect(ads.completeLoad(token: secondLoad, succeeded: true, now: loadedAt), "replacement load accepted")
expect(ads.beginPresentation(adID: UUID(), now: loadedAt) == nil, "wrong ad identity cannot present")
let presentation = ads.beginPresentation(adID: secondLoad, now: loadedAt)!
expect(ads.cachedAdID == nil, "presentation consumes cached ad")
expect(ads.beginPresentation(adID: secondLoad, now: loadedAt) == nil, "duplicate presentation rejected")
expect(ads.beginLoad() == nil, "no prefetch during presentation")
expect(!ads.grantReward(token: UUID(), adID: secondLoad), "wrong presentation token cannot grant")
expect(!ads.grantReward(token: presentation, adID: UUID()), "wrong ad identity cannot grant")
expect(ads.grantReward(token: presentation, adID: secondLoad), "earned reward delivered")
expect(!ads.grantReward(token: presentation, adID: secondLoad), "duplicate reward ignored")
expect(ads.isPresenting, "busy retained after reward until dismissal")
expect(ads.beginLoad() == nil, "reward does not permit another load before dismissal")
expect(ads.endPresentation(token: UUID(), adID: secondLoad) == nil, "old dismissal cannot end current ad")
expect(ads.endPresentation(token: presentation, adID: UUID()) == nil, "wrong ad cannot end presentation")
expect(ads.endPresentation(token: presentation, adID: secondLoad) == false, "earned reward not followed by false callback")
expect(!ads.isPresenting, "dismissal releases busy state")
expect(ads.endPresentation(token: presentation, adID: secondLoad) == nil, "duplicate dismissal ignored")

let thirdLoad = ads.beginLoad()!
expect(ads.completeLoad(token: thirdLoad, succeeded: true, now: loadedAt), "next ad loaded")
let nextPresentation = ads.beginPresentation(adID: thirdLoad, now: loadedAt)!
expect(!ads.grantReward(token: presentation, adID: secondLoad), "late previous reward cannot affect next presentation")
expect(ads.endPresentation(token: presentation, adID: secondLoad) == nil, "late previous failure cannot end next presentation")
expect(ads.endPresentation(token: nextPresentation, adID: thirdLoad) == true, "early dismissal or presentation failure returns false once")
expect(ads.endPresentation(token: nextPresentation, adID: thirdLoad) == nil, "early-dismiss callback is once only")

let failedLoad = ads.beginLoad()!
expect(ads.completeLoad(token: failedLoad, succeeded: false, now: loadedAt), "offline load failure accepted")
expect(ads.cachedAdID == nil, "load failure has no usable reward")
let obsoleteLoad = ads.beginLoad()!
ads.invalidateCache()
let currentLoad = ads.beginLoad()!
expect(!ads.completeLoad(token: obsoleteLoad, succeeded: true, now: loadedAt), "late load after privacy change ignored")
expect(ads.loadToken == currentLoad, "late load leaves current request intact")
expect(ads.completeLoad(token: currentLoad, succeeded: true, now: loadedAt), "current request after privacy change accepted")
expect(ads.expireCache(now: loadedAt.addingTimeInterval(-1)), "clock rollback does not extend cached ad lifetime")

var startup = AdSDKStartup()
expect(!startup.claimStart(canRequestAds: false), "no SDK start without consent permission")
expect(!startup.requested, "offline consent failure remains retryable")
expect(startup.claimStart(canRequestAds: true), "SDK starts after permission")
expect(!startup.claimStart(canRequestAds: true), "duplicate consent completions do not restart SDK")
expect(!startup.claimStart(canRequestAds: false), "revocation cannot start SDK")
expect(!startup.claimStart(canRequestAds: true), "later consent reuses the initialized SDK")

print("App policies: \(checks) checks passed")
