import UIKit
import WebKit
import GoogleMobileAds

var sharedWebView: WKWebView! = nil

class ViewController: UIViewController, WKNavigationDelegate, UIDocumentInteractionControllerDelegate {
    enum LoadingMode {
        case defaultCachePolicy
        case forceCache
    }

    var documentController: UIDocumentInteractionController?
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    @IBOutlet weak var loadingView: UIView!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var connectionProblemView: UIImageView!
    @IBOutlet weak var webviewView: UIView!
    var toolbarView: UIToolbar!
    var bannerView: GADBannerView!
    // Desired banner visibility as last reported by the web content, kept
    // separately since it can be set before bannerView exists.
    private var bannerShouldBeVisible = false
    private var bannerScreen = "unknown"
    private var bannerRequestFailed = false
    private var bannerHasLoaded = false
    private var privacyOptionsButton: UIButton!

    var htmlIsLoaded = false;
    private var loadingMode = LoadingMode.defaultCachePolicy
    
    private var themeObservation: NSKeyValueObservation?
    var currentWebViewTheme: UIUserInterfaceStyle = .unspecified
    override var preferredStatusBarStyle : UIStatusBarStyle {
        if #available(iOS 13, *), overrideStatusBar{
            if #available(iOS 15, *) {
                return .default
            } else {
                return statusBarTheme == "dark" ? .lightContent : .darkContent
            }
        }
        return .default
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        loadingView.backgroundColor = .white
        webviewView.backgroundColor = .white
        initWebView()
        initToolbarView()
        initPrivacyOptionsButton()
        AdManager.shared.stateDidChange = { [weak self] in self?.updateAdAvailability() }
        loadRootUrl()

        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification , object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(adsDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        adsDidBecomeActive()
    }

    @objc private func adsDidBecomeActive() {
        AdManager.shared.prepareAds(from: self)
        retryFailedBanner()
        updateAdAvailability()
    }

    private func initPrivacyOptionsButton() {
        let button = UIButton(type: .system)
        button.setTitle("広告のプライバシー設定", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: #selector(showPrivacyOptions), for: .touchUpInside)
        button.backgroundColor = .systemBackground
        button.isHidden = true
        webviewView.addSubview(button)
        privacyOptionsButton = button
    }

    private func updateAdAvailability() {
        if !AdManager.shared.canLoadAds {
            bannerView?.delegate = nil
            bannerView?.removeFromSuperview()
            bannerView = nil
            bannerRequestFailed = false
            bannerHasLoaded = false
            bannerAdHeight = 0
        }
        // Keep this real user control on the home screen and reserve its space.
        privacyOptionsButton.isHidden = bannerScreen != "home" || !htmlIsLoaded
            || !AdManager.shared.privacyOptionsRequired
        privacyOptionsButton.isEnabled = !AdManager.shared.consentFlowInProgress
        view.setNeedsLayout()
    }

    @objc private func showPrivacyOptions() {
        AdManager.shared.presentPrivacyOptions(from: self) { [weak self] succeeded in
            guard let self, !succeeded, self.viewIfLoaded?.window != nil,
                  self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "設定を開けませんでした", message: "通信を確認して、もう一度お試しください。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "閉じる", style: .default))
            self.present(alert, animated: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Deferred from viewDidLoad: webviewView.frame.width isn't reliably
        // final until the first layout pass, and creating the adaptive
        // banner with a zero/stale width breaks ad loading entirely.
        if bannerView == nil && webviewView.frame.width > 0 && AdManager.shared.canLoadAds {
            initBannerAd()
        }
        layoutBannerAd()
        var gameFrame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
        if !privacyOptionsButton.isHidden {
            let buttonHeight = max(44, (privacyOptionsButton.titleLabel?.font.lineHeight ?? 20) + 20)
            let reservedHeight = buttonHeight + view.safeAreaInsets.bottom
            privacyOptionsButton.frame = CGRect(x: 12, y: gameFrame.maxY - reservedHeight,
                                                width: max(0, gameFrame.width - 24), height: buttonHeight)
            gameFrame.size.height = max(0, gameFrame.height - reservedHeight)
            webviewView.bringSubviewToFront(privacyOptionsButton)
        }
        sharedWebView.frame = gameFrame
    }
    
    @objc func keyboardWillHide(_ notification: NSNotification) {
        sharedWebView.setNeedsLayout()
    }
    
    func initWebView() {
        sharedWebView = createWebView(container: webviewView, WKSMH: self, WKND: self)
        webviewView.addSubview(sharedWebView);
        
        sharedWebView.uiDelegate = self;
        sharedWebView.backgroundColor = .white
        sharedWebView.scrollView.backgroundColor = .white
        if #available(iOS 15.0, *) {
            sharedWebView.underPageBackgroundColor = .white
        }
        
        sharedWebView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        if(pullToRefresh){
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(refreshWebView(_:)), for: UIControl.Event.valueChanged)
            sharedWebView.scrollView.addSubview(refreshControl)
            sharedWebView.scrollView.bounces = true
        }

        if #available(iOS 15.0, *), adaptiveUIStyle {
            themeObservation = sharedWebView.observe(\.themeColor) { [unowned self] webView, _ in
                let backgroundColor = sharedWebView.underPageBackgroundColor;
                let themeColor = sharedWebView.themeColor;
                currentWebViewTheme = themeColor?.isLight() ?? backgroundColor?.isLight() ?? true ? .light : .dark
                self.overrideUIStyle()
                view.backgroundColor = themeColor ?? backgroundColor;
            }
        }
    }

    @objc func refreshWebView(_ sender: UIRefreshControl) {
        sharedWebView?.reload()
        sender.endRefreshing()
    }

    func createToolbarView() -> UIToolbar{
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 60
        
        #if targetEnvironment(macCatalyst)
        if (statusBarHeight == 0){
            statusBarHeight = 30
        }
        #endif
        
        let toolbarView = UIToolbar(frame: CGRect(x: 0, y: 0, width: webviewView.frame.width, height: 0))
        toolbarView.sizeToFit()
        toolbarView.frame = CGRect(x: 0, y: 0, width: webviewView.frame.width, height: toolbarView.frame.height + statusBarHeight)
//        toolbarView.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleWidth]
        
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(loadRootUrl))
        toolbarView.setItems([close,flex], animated: true)
        
        toolbarView.isHidden = true
        
        return toolbarView
    }
    
    func overrideUIStyle(toDefault: Bool = false) {
        if #available(iOS 15.0, *), adaptiveUIStyle {
            if (((htmlIsLoaded && !sharedWebView.isHidden) || toDefault) && self.currentWebViewTheme != .unspecified) {
                UIApplication
                    .shared
                    .connectedScenes
                    .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                    .first { $0.isKeyWindow }?.overrideUserInterfaceStyle = toDefault ? .unspecified : self.currentWebViewTheme;
            }
        }
    }
    
    func initToolbarView() {
        toolbarView =  createToolbarView()

        webviewView.addSubview(toolbarView)
    }

    // Persistent banner ad pinned to the bottom of the puzzle (game) screen
    // only. Hidden on every other screen (home/list/daily) — see
    // setBannerVisible, driven by the web content's "screen" messages.
    // The webview's own frame (see calcWebviewFrame) is shrunk by
    // bannerAdHeight so the banner never overlaps gameplay UI.
    func initBannerAd() {
        guard AdManager.shared.canLoadAds else { return }
        bannerRequestFailed = false
        bannerHasLoaded = false
        bannerView = AdManager.shared.makeBannerView(rootViewController: self, width: webviewView.frame.width, delegate: self)
        // Apply whatever visibility the web content already asked for —
        // its "screen" message may have arrived before the banner existed.
        bannerView.isHidden = true
        webviewView.addSubview(bannerView)
        layoutBannerAd()
        // Install the view and delegate before a load can report a result.
        AdManager.shared.loadBanner(bannerView)
    }

    @objc private func retryFailedBanner() {
        // A pending or successful request must never be restarted by a tap.
        guard bannerRequestFailed, bannerShouldBeVisible, AdManager.shared.canLoadAds,
              view.window != nil, UIApplication.shared.applicationState == .active else { return }
        bannerRequestFailed = false
        // Retire the old view so its automatic refresh cannot compete with
        // this explicit retry. Late callbacks are ignored by identity below.
        bannerView?.delegate = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
        initBannerAd()
        view.setNeedsLayout()
    }

    func layoutBannerAd() {
        guard let bannerView = bannerView else { bannerAdHeight = 0; return }
        let bottomInset = view.safeAreaInsets.bottom
        bannerView.frame = CGRect(
            x: (webviewView.frame.width - bannerView.frame.width) / 2,
            y: webviewView.frame.height - bannerView.frame.height - bottomInset,
            width: bannerView.frame.width,
            height: bannerView.frame.height
        )
        bannerAdHeight = bannerView.isHidden ? 0 : bannerView.frame.height + bottomInset
    }

    func setBannerVisible(_ visible: Bool) {
        bannerShouldBeVisible = visible
        let shouldShow = visible && bannerHasLoaded
        guard let bannerView = bannerView, bannerView.isHidden == shouldShow else { return }
        bannerView.isHidden = !shouldShow
        layoutBannerAd()
        // The parent recomputes the WKWebView frame in viewDidLayoutSubviews.
        view.setNeedsLayout()
    }
    
    @objc func loadRootUrl(cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) {
        sharedWebView.load(URLRequest(url: SceneDelegate.universalLinkToLaunch ?? SceneDelegate.shortcutLinkToLaunch ?? rootUrl, cachePolicy: cachePolicy))
    }
    
    func reloadWebview(
        loadingMode: LoadingMode = LoadingMode.defaultCachePolicy
    ) {
        switch loadingMode {
        case LoadingMode.defaultCachePolicy:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);

        case LoadingMode.forceCache:
            loadRootUrl(cachePolicy: .returnCacheDataElseLoad);
        }

        self.loadingMode = loadingMode
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!){
        htmlIsLoaded = true
        updateAdAvailability()
        #if DEBUG
        NSLog("NANPURE_DIAGNOSTICS web=loaded")
        #endif
        
        self.setProgress(1.0, true)
        self.animateConnectionProblem(false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            sharedWebView.isHidden = false
            self.loadingView.isHidden = true
           
            self.setProgress(0.0, false)
            
            self.overrideUIStyle()
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        htmlIsLoaded = false;
        
        if (error as NSError)._code == (-999) { return }
        if (error as NSError)._code == 102 { return }
        
        self.overrideUIStyle(toDefault: true);
        webView.isHidden = true;
        loadingView.isHidden = false;

        if loadingMode == LoadingMode.defaultCachePolicy {
            DispatchQueue.main.async {
                self.reloadWebview(loadingMode: LoadingMode.forceCache)
            }
        } else {
            animateConnectionProblem(true);
            setProgress(0.05, true);
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.setProgress(0.1, true);
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.reloadWebview()
                }
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {

        if (keyPath == #keyPath(WKWebView.estimatedProgress) &&
                sharedWebView.isLoading &&
                !self.loadingView.isHidden &&
                !self.htmlIsLoaded) {
                    var progress = Float(sharedWebView.estimatedProgress);
                    
                    if (progress >= 0.8) { progress = 1.0; };
                    if (progress >= 0.3) { self.animateConnectionProblem(false); }
                    
                    self.setProgress(progress, true);
        }
    }
    
    func setProgress(_ progress: Float, _ animated: Bool) {
        self.progressView.setProgress(progress, animated: animated);
    }
    
    
    func animateConnectionProblem(_ show: Bool) {
        if (show) {
            self.connectionProblemView.isHidden = false;
            self.connectionProblemView.alpha = 0
            UIView.animate(withDuration: 0.7, delay: 0, options: [.repeat, .autoreverse], animations: {
                self.connectionProblemView.alpha = 1
            })
        }
        else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [], animations: {
                self.connectionProblemView.alpha = 0 // Here you will get the animation you want
            }, completion: { _ in
                self.connectionProblemView.isHidden = true;
                self.connectionProblemView.layer.removeAllAnimations();
            })
        }
    }
        
    deinit {
        NotificationCenter.default.removeObserver(self)
        sharedWebView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
}

extension UIColor {
    // Check if the color is light or dark, as defined by the injected lightness threshold.
    // Some people report that 0.7 is best. I suggest to find out for yourself.
    // A nil value is returned if the lightness couldn't be determined.
    func isLight(threshold: Float = 0.5) -> Bool? {
        let originalCGColor = self.cgColor

        // Now we need to convert it to the RGB colorspace. UIColor.white / UIColor.black are greyscale and not RGB.
        // If you don't do this then you will crash when accessing components index 2 below when evaluating greyscale colors.
        let RGBCGColor = originalCGColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        guard let components = RGBCGColor?.components else {
            return nil
        }
        guard components.count >= 3 else {
            return nil
        }

        let brightness = Float(((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000)
        return (brightness > threshold)
    }
}

extension ViewController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === sharedWebView, isTrustedGameFrame(message.frameInfo) else { return }
        if message.name == "print" {
            printView(webView: sharedWebView)
        }
        else if message.name == "nativeAd" {
            handleNativeAdMessage(message.body)
        }
        else if message.name == "screen" {
            handleScreenMessage(message.body)
        }
  }

  // Shows the banner ad only while the web content is on the "game"
  // (puzzle-playing) screen, per: window.webkit.messageHandlers.screen.postMessage({screen: "game"})
  func handleScreenMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let screen = dict["screen"] as? String else { return }
        bannerScreen = screen
        setBannerVisible(screen == "game")
        if screen == "game" {
            retryFailedBanner()
        }
        updateAdAvailability()
  }

  // Handles requests from the web content to show a native ad, e.g.:
  //   window.webkit.messageHandlers.nativeAd.postMessage({type: "showRewardedAd", requestId: "..."})
  // The result is reported back via window.__nativeAdCallback(requestId, granted).
  func handleNativeAdMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              let requestId = dict["requestId"] as? String else { return }

        switch type {
        case "showRewardedAd":
            AdManager.shared.presentRewardedAd(from: self) { granted in
                DispatchQueue.main.async {
                    self.resolveNativeAd(requestId: requestId, granted: granted)
                }
            }
        default:
            resolveNativeAd(requestId: requestId, granted: false)
        }
  }

  func resolveNativeAd(requestId: String, granted: Bool) {
        // requestId is generated by our own web content, but validate it
        // anyway before splicing it into a JS string literal.
        guard requestId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return }
        let script = "window.__nativeAdCallback && window.__nativeAdCallback('\(requestId)', \(granted));"
        sharedWebView.evaluateJavaScript(script, completionHandler: nil)
  }
}

extension ViewController: GADBannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
        guard bannerView === self.bannerView else { return }
        #if DEBUG
        NSLog("NANPURE_DIAGNOSTICS banner=loaded")
        #endif
        bannerRequestFailed = false
        bannerHasLoaded = true
        setBannerVisible(bannerShouldBeVisible)
        layoutBannerAd()
        view.setNeedsLayout()
    }

    func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
        guard bannerView === self.bannerView else { return }
        bannerRequestFailed = true
        bannerHasLoaded = false
        setBannerVisible(bannerShouldBeVisible)
        #if DEBUG
        let adError = error as NSError
        NSLog("NANPURE_DIAGNOSTICS banner=failed domain=%@ code=%ld", adError.domain, adError.code)
        #endif
    }
}
