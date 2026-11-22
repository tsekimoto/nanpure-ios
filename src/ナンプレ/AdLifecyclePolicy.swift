import Foundation

// Tokens prevent delayed SDK callbacks from changing a newer load/presentation.
struct RewardedAdLifecycle {
    private(set) var loadToken: UUID?
    private(set) var cachedAdID: UUID?
    private var loadedAt: Date?
    private(set) var presentationToken: UUID?
    private var presentingAdID: UUID?
    private var rewardDelivered = false

    var isPresenting: Bool { presentationToken != nil }

    mutating func beginLoad() -> UUID? {
        guard loadToken == nil, cachedAdID == nil, !isPresenting else { return nil }
        let token = UUID()
        loadToken = token
        return token
    }

    mutating func completeLoad(token: UUID, succeeded: Bool, now: Date) -> Bool {
        guard loadToken == token else { return false }
        loadToken = nil
        if succeeded {
            cachedAdID = token
            loadedAt = now
        }
        return true
    }

    func hasFreshAd(now: Date) -> Bool {
        guard cachedAdID != nil, let loadedAt else { return false }
        let age = now.timeIntervalSince(loadedAt)
        return age >= 0 && age < 3_600
    }

    @discardableResult
    mutating func expireCache(now: Date) -> Bool {
        guard cachedAdID != nil, !hasFreshAd(now: now) else { return false }
        cachedAdID = nil
        loadedAt = nil
        return true
    }

    mutating func invalidateCache() {
        loadToken = nil
        cachedAdID = nil
        loadedAt = nil
    }

    mutating func beginPresentation(adID: UUID, now: Date) -> UUID? {
        guard !isPresenting, cachedAdID == adID, hasFreshAd(now: now) else { return nil }
        let token = UUID()
        presentationToken = token
        presentingAdID = adID
        rewardDelivered = false
        cachedAdID = nil
        loadedAt = nil
        return token
    }

    mutating func grantReward(token: UUID, adID: UUID) -> Bool {
        guard presentationToken == token, presentingAdID == adID, !rewardDelivered else { return false }
        rewardDelivered = true
        return true
    }

    // nil = stale callback; true = caller still owes a false completion;
    // false = reward was already delivered. Busy ends here, not at reward.
    mutating func endPresentation(token: UUID, adID: UUID) -> Bool? {
        guard presentationToken == token, presentingAdID == adID else { return nil }
        let needsFailureCompletion = !rewardDelivered
        presentationToken = nil
        presentingAdID = nil
        rewardDelivered = false
        return needsFailureCompletion
    }
}

struct AdSDKStartup {
    private(set) var requested = false

    mutating func claimStart(canRequestAds: Bool) -> Bool {
        guard canRequestAds, !requested else { return false }
        requested = true
        return true
    }
}
