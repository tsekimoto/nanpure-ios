import UIKit
import GoogleMobileAds

// TEMP FOR TESTING: Google's official test ad unit IDs, swapped in while our
// own AdMob app is still "要審査" and real ad units may have no fill.
// Real IDs (restore before submitting for App Review):
//   banner:   ca-app-pub-7659346445516782/8870201118
//   rewarded: ca-app-pub-7659346445516782/4139518536
private let bannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
private let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"

final class AdManager: NSObject {
    static let shared = AdManager()

    private var rewardedAd: GADRewardedAd?
    private var pendingRewardCallback: ((Bool) -> Void)?

    private override init() {}

    func start() {
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        loadRewardedAd()
    }

    // Non-personalized ads only: no IDFA/tracking is requested, so no ATT
    // prompt is needed. See https://developers.google.com/admob/ios/eu-consent
    private func makeRequest() -> GADRequest {
        let request = GADRequest()
        let extras = GADExtras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    func makeBannerView(rootViewController: UIViewController, width: CGFloat) -> GADBannerView {
        let adSize = GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(width)
        let bannerView = GADBannerView(adSize: adSize)
        bannerView.adUnitID = bannerAdUnitID
        bannerView.rootViewController = rootViewController
        bannerView.load(makeRequest())
        return bannerView
    }

    private func loadRewardedAd() {
        GADRewardedAd.load(withAdUnitID: rewardedAdUnitID, request: makeRequest()) { [weak self] ad, error in
            guard let self else { return }
            if let error {
                print("Rewarded ad failed to load: \(error.localizedDescription)")
                return
            }
            self.rewardedAd = ad
            self.rewardedAd?.fullScreenContentDelegate = self
        }
    }

    // Presents a rewarded ad. `completion` is called with `true` only if the
    // user watched far enough to earn the reward, `false` otherwise (ad not
    // ready, failed to present, or dismissed early).
    func presentRewardedAd(from viewController: UIViewController, completion: @escaping (Bool) -> Void) {
        guard let rewardedAd else {
            completion(false)
            loadRewardedAd()
            return
        }
        pendingRewardCallback = completion
        rewardedAd.present(fromRootViewController: viewController) { [weak self] in
            self?.pendingRewardCallback?(true)
            self?.pendingRewardCallback = nil
        }
    }
}

extension AdManager: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        rewardedAd = nil
        loadRewardedAd()
        // If still set here, the reward handler above never fired, i.e. the
        // user closed the ad before earning the reward.
        pendingRewardCallback?(false)
        pendingRewardCallback = nil
    }

    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        rewardedAd = nil
        pendingRewardCallback?(false)
        pendingRewardCallback = nil
        loadRewardedAd()
    }
}
