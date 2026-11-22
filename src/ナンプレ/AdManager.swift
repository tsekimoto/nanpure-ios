import UIKit
import GoogleMobileAds
import UserMessagingPlatform

#if DEBUG
private let bannerAdUnitID = "ca-app-pub-3940256099942544/2435281174"
private let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"
#else
private let bannerAdUnitID = "ca-app-pub-7659346445516782/8870201118"
private let rewardedAdUnitID = "ca-app-pub-7659346445516782/4139518536"
#endif

final class AdManager: NSObject {
    static let shared = AdManager()
    var stateDidChange: (() -> Void)?

    private var startup = AdSDKStartup()
    private var sdkReady = false
    private var consentUpdateStarted = false
    private var consentRefreshNeeded = true
    private(set) var consentFlowInProgress = false
    private var lifecycle = RewardedAdLifecycle()
    private var rewardedAd: GADRewardedAd?
    private var presentingAd: GADRewardedAd?
    private var presentationDelegate: RewardPresentationDelegate?
    private var pendingRewardCallback: ((Bool) -> Void)?

    private override init() {}

    var privacyOptionsRequired: Bool {
        UMPConsentInformation.sharedInstance.privacyOptionsRequirementStatus == .required
    }

    private var consentAllowsAds: Bool {
        consentUpdateStarted && !consentFlowInProgress
            && UMPConsentInformation.sharedInstance.canRequestAds
    }

    var canLoadAds: Bool { sdkReady && consentAllowsAds }

    // The game starts independently, including offline. Retry failed consent
    // work on the next foreground without hiding or reloading the game.
    func prepareAds(from viewController: UIViewController) {
        guard viewController.viewIfLoaded?.window != nil,
              UIApplication.shared.applicationState == .active else { return }
        guard !consentFlowInProgress, !lifecycle.isPresenting else { return }
        guard consentRefreshNeeded else {
            resumeAdsIfAllowed()
            return
        }
        guard viewController.presentedViewController == nil else { return }
        consentFlowInProgress = true
        consentUpdateStarted = true
        discardCachedReward()
        stateDidChange?()
        UMPConsentInformation.sharedInstance.requestConsentInfoUpdate(with: UMPRequestParameters()) { [weak self, weak viewController] error in
            guard let self else { return }
            if error != nil {
                self.finishConsentFlow(succeeded: false)
                return
            }
            guard let viewController, viewController.viewIfLoaded?.window != nil,
                  UIApplication.shared.applicationState == .active,
                  viewController.presentedViewController == nil else {
                self.finishConsentFlow(succeeded: false)
                return
            }
            UMPConsentForm.loadAndPresentIfRequired(from: viewController) { [weak self] error in
                self?.finishConsentFlow(succeeded: error == nil)
            }
        }
    }

    func presentPrivacyOptions(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        guard privacyOptionsRequired, !consentFlowInProgress, !lifecycle.isPresenting,
              viewController.viewIfLoaded?.window != nil,
              viewController.presentedViewController == nil,
              UIApplication.shared.applicationState == .active else {
            completion(false)
            return
        }
        consentFlowInProgress = true
        discardCachedReward()
        stateDidChange?()
        UMPConsentForm.presentPrivacyOptionsForm(from: viewController) { [weak self] error in
            self?.finishConsentFlow(succeeded: error == nil)
            completion(error == nil)
        }
    }

    private func finishConsentFlow(succeeded: Bool) {
        consentFlowInProgress = false
        consentRefreshNeeded = !succeeded
        // UMP can retain a valid previous-session choice when an update fails.
        resumeAdsIfAllowed()
        stateDidChange?()
    }

    private func resumeAdsIfAllowed() {
        guard consentAllowsAds else {
            discardCachedReward()
            stateDidChange?()
            return
        }
        if startup.claimStart(canRequestAds: consentAllowsAds) {
            // Retain non-personalized requests and the existing no-ATT approach.
            GADMobileAds.sharedInstance().requestConfiguration.setPublisherFirstPartyIDEnabled(false)
            GADMobileAds.sharedInstance().start { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sdkReady = true
                    self.loadRewardedAd()
                    self.stateDidChange?()
                }
            }
        } else if sdkReady {
            loadRewardedAd()
        }
    }

    private func makeRequest() -> GADRequest {
        let request = GADRequest()
        let extras = GADExtras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    func makeBannerView(rootViewController: UIViewController, width: CGFloat, delegate: GADBannerViewDelegate) -> GADBannerView {
        let adSize = GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(width)
        let bannerView = GADBannerView(adSize: adSize)
        bannerView.adUnitID = bannerAdUnitID
        bannerView.rootViewController = rootViewController
        bannerView.delegate = delegate
        return bannerView
    }

    func loadBanner(_ bannerView: GADBannerView) {
        guard canLoadAds else { return }
        bannerView.load(makeRequest())
    }

    private func discardCachedReward() {
        lifecycle.invalidateCache()
        rewardedAd = nil
    }

    private func loadRewardedAd() {
        guard canLoadAds else { return }
        if lifecycle.expireCache(now: Date()) { rewardedAd = nil }
        guard let token = lifecycle.beginLoad() else { return }
        GADRewardedAd.load(withAdUnitID: rewardedAdUnitID, request: makeRequest()) { [weak self] ad, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let succeeded = error == nil && ad != nil && self.canLoadAds
                guard self.lifecycle.completeLoad(token: token, succeeded: succeeded, now: Date()) else { return }
                self.rewardedAd = succeeded ? ad : nil
                #if DEBUG
                if succeeded {
                    NSLog("NANPURE_DIAGNOSTICS rewarded=loaded")
                } else if let error {
                    let adError = error as NSError
                    NSLog("NANPURE_DIAGNOSTICS rewarded=failed domain=%@ code=%ld", adError.domain, adError.code)
                }
                #endif
            }
        }
    }

    func presentRewardedAd(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        guard canLoadAds, !lifecycle.isPresenting,
              viewController.viewIfLoaded?.window != nil,
              viewController.presentedViewController == nil,
              UIApplication.shared.applicationState == .active else {
            completion(false)
            return
        }
        if lifecycle.expireCache(now: Date()) { rewardedAd = nil }
        guard let ad = rewardedAd, let adID = lifecycle.cachedAdID,
              let token = lifecycle.beginPresentation(adID: adID, now: Date()) else {
            completion(false)
            loadRewardedAd()
            return
        }
        rewardedAd = nil
        presentingAd = ad
        pendingRewardCallback = completion
        let delegate = RewardPresentationDelegate { [weak self] callbackAd in
            self?.finishPresentation(ad: callbackAd, token: token, adID: adID)
        }
        presentationDelegate = delegate
        ad.fullScreenContentDelegate = delegate
        ad.present(fromRootViewController: viewController) { [weak self, weak ad] in
            guard let self, let ad, self.presentingAd === ad,
                  self.lifecycle.grantReward(token: token, adID: adID) else { return }
            let callback = self.pendingRewardCallback
            self.pendingRewardCallback = nil
            callback?(true)
        }
    }

    private func finishPresentation(ad: GADFullScreenPresentingAd, token: UUID, adID: UUID) {
        guard let presentingAd, (ad as AnyObject) === presentingAd,
              let needsFailure = lifecycle.endPresentation(token: token, adID: adID) else { return }
        let callback = pendingRewardCallback
        pendingRewardCallback = nil
        presentingAd.fullScreenContentDelegate = nil
        self.presentingAd = nil
        presentationDelegate = nil
        if needsFailure { callback?(false) }
        loadRewardedAd()
    }
}

private final class RewardPresentationDelegate: NSObject, GADFullScreenContentDelegate {
    private let finish: (GADFullScreenPresentingAd) -> Void

    init(finish: @escaping (GADFullScreenPresentingAd) -> Void) {
        self.finish = finish
        super.init()
    }

    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) { finish(ad) }

    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) { finish(ad) }
}
