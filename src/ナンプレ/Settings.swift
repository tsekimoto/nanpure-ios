import WebKit

struct Cookie {
    var name: String
    var value: String
}

// URL for first launch
let rootUrl = URL(string: "https://tsekimoto.github.io/nanpure-pwa/")!

// Exact HTTPS hosts allowed inside the game web view. App-Bound Domains cannot
// be used app-wide because that also prevents the ad SDK's web views loading.
let allowedOrigins: [String] = ["tsekimoto.github.io"]
let webContentPolicy = WebContentPolicy(allowedHosts: allowedOrigins)

let platformCookie = Cookie(name: "app-platform", value: "iOS App Store")

// UI options
let displayMode = "standalone" // standalone / fullscreen.
let adaptiveUIStyle = false    // Keep the native shell light so the PWA background never follows iOS dark mode.
let overrideStatusBar = false   // iOS 13-14 only. if you don't support dark/light system theme.
let statusBarTheme = "dark"    // dark / light, related to override option.
let pullToRefresh = true    // Enable/disable pull down to refresh page

// Height reserved at the bottom of the webview for the persistent ad banner.
// Updated once the banner's adaptive size is known (see ViewController.layoutBannerAd).
var bannerAdHeight: CGFloat = 0
