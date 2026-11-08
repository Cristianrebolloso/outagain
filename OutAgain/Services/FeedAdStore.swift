import GoogleMobileAds
import Observation
import SwiftUI
import UserMessagingPlatform

@MainActor @Observable
final class FeedAdSlot {
    let id: UUID
    var ad: NativeAd?
    var measuredHeight: CGFloat = 0
    var isVisible = false
    var lastUsed = Date()
    var loadedAt: Date?
    var failedAt: Date?

    init(id: UUID) { self.id = id }
}

/// Shared by the phone and Duo shells so folding and profile navigation do not
/// recreate ads. It never receives a profile, location, photo, or social graph.
@MainActor @Observable
final class FeedAdStore {
    private(set) var slots: [UUID: FeedAdSlot] = [:]
    private(set) var isPrivacyOptionsRequired = false
    private(set) var isPresentingPrivacyOptions = false
    var privacyError: String?

    @ObservationIgnored private let configuration = FeedAdConfiguration.current
    @ObservationIgnored private var loaders: [UUID: FeedNativeAdRequest] = [:]
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var sdkReady = false
    @ObservationIgnored private var canRequestAds = false
    @ObservationIgnored private var feedEnabled = false
    @ObservationIgnored private var lastRequestedAnchor: UUID?
    @ObservationIgnored private var consentUpdateFailed = false
    @ObservationIgnored private var lastConsentAttempt = Date.distantPast

    func prepare(postIDs: [UUID], isLayoutPreview: Bool) async {
        // Existing offline layout checks must stay offline. This opt-in preview
        // exercises Google's real test-ad delivery with the local sample feed.
        feedEnabled = configuration.unitID != nil && (!isLayoutPreview ||
            ProcessInfo.processInfo.arguments.contains("--feed-ads-preview"))
        guard feedEnabled else { return }
        let eligible = Set(FeedAdPlacement.anchors(in: postIDs))
        slots = slots.filter { eligible.contains($0.key) }
        loaders = loaders.filter { eligible.contains($0.key) }
        for id in eligible where slots[id] == nil { slots[id] = FeedAdSlot(id: id) }
        await prepareSDK()
        guard !Task.isCancelled else { return }
        request(lastRequestedAnchor.flatMap { eligible.contains($0) ? $0 : nil }
            ?? FeedAdPlacement.anchors(in: postIDs).first)
    }

    func postAppeared(at index: Int, postIDs: [UUID]) {
        let anchor = FeedAdPlacement.nextAnchor(after: index, in: postIDs)
        lastRequestedAnchor = anchor
        request(anchor)
        if feedEnabled, consentUpdateFailed, Date().timeIntervalSince(lastConsentAttempt) >= 60 {
            Task {
                await prepareSDK()
                request(lastRequestedAnchor)
            }
        }
    }

    func appeared(_ slot: FeedAdSlot) {
        slot.isVisible = true
        slot.lastUsed = .now
        request(slot.id)
    }

    func disappeared(_ slot: FeedAdSlot) {
        slot.isVisible = false
        trimCache()
    }

    func clearFeed() {
        loaders.removeAll()
        slots.removeAll()
        lastRequestedAnchor = nil
        feedEnabled = false
    }

    func presentPrivacyOptions() async {
        guard isPrivacyOptionsRequired, !isPresentingPrivacyOptions else { return }
        isPresentingPrivacyOptions = true
        defer { isPresentingPrivacyOptions = false }
        // Discard creatives loaded under the previous privacy choice.
        loaders.removeAll()
        for slot in slots.values { slot.ad = nil; slot.loadedAt = nil; slot.failedAt = nil }
        canRequestAds = false
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: nil)
        } catch {
            privacyError = "Ad privacy choices could not be opened. Please try again."
        }
        await startIfAllowed()
        isPresentingPrivacyOptions = false
        for slot in slots.values where slot.isVisible { request(slot.id) }
        request(lastRequestedAnchor)
    }

    private func prepareSDK() async {
        if preparation == nil || (consentUpdateFailed && Date().timeIntervalSince(lastConsentAttempt) >= 60) {
            lastConsentAttempt = .now
            consentUpdateFailed = false
            preparation = Task { await gatherConsentAndStart() }
        }
        await preparation?.value
    }

    private func gatherConsentAndStart() async {
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch {
            consentUpdateFailed = true
            // UMP can still authorize requests using a valid prior-session
            // choice. Otherwise ads stay absent and the feed works normally.
            #if DEBUG
            print("[FeedAds] Consent: \(error.localizedDescription)")
            #endif
        }
        await startIfAllowed()
    }

    private func startIfAllowed() async {
        isPrivacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        canRequestAds = ConsentInformation.shared.canRequestAds
        if !canRequestAds {
            for slot in slots.values { slot.ad = nil; slot.measuredHeight = 0 }
        }
        guard canRequestAds, !sdkReady else { return }
        // This integration does not request ATT or access an advertising ID.
        // Also disable Google's publisher first-party identifier.
        MobileAds.shared.requestConfiguration.setPublisherFirstPartyIDEnabled(false)
        MobileAds.shared.requestConfiguration.publisherPrivacyPersonalizationState = .disabled
        // Camera/post location permission must not become ad location permission.
        MobileAds.shared.requestConfiguration.coarseLocationCollectionEnabled = false
        MobileAds.shared.isApplicationMuted = true
        await MobileAds.shared.start()
        sdkReady = true
    }

    private func request(_ id: UUID?) {
        guard feedEnabled, canRequestAds, sdkReady, !isPresentingPrivacyOptions,
              ConsentInformation.shared.canRequestAds,
              let id, let slot = slots[id], let unitID = configuration.unitID,
              loaders[id] == nil else { return }
        if let loaded = slot.loadedAt, Date().timeIntervalSince(loaded) >= 3_600 {
            slot.ad = nil
            slot.loadedAt = nil
        }
        guard slot.ad == nil else { return }
        if let failed = slot.failedAt, Date().timeIntervalSince(failed) < 60 { return }
        slot.lastUsed = .now
        let loader = FeedNativeAdRequest(unitID: unitID) { [weak self, weak slot] result in
            guard let self, let slot, self.slots[id] === slot else { return }
            self.loaders[id] = nil
            switch result {
            case .success(let ad):
                slot.ad = ad
                slot.loadedAt = .now
                slot.failedAt = nil
                #if DEBUG
                print("[FeedAds] Native ad ready")
                #endif
            case .failure:
                slot.failedAt = .now
                slot.measuredHeight = 0
            }
            self.trimCache()
        }
        loaders[id] = loader
        loader.load()
    }

    private func trimCache() {
        // Preload only the upcoming slot; keep at most four offscreen/visible
        // creatives in ordinary use. Never evict a visible card mid-interaction.
        let loaded = slots.values.filter { $0.ad != nil }.sorted { $0.lastUsed < $1.lastUsed }
        var excess = loaded.count - 4
        for slot in loaded where excess > 0 && !slot.isVisible {
            slot.ad = nil
            slot.loadedAt = nil
            excess -= 1
        }
    }
}

@MainActor
private final class FeedNativeAdRequest: NSObject, NativeAdLoaderDelegate {
    private let loader: AdLoader
    private let completion: (Result<NativeAd, Error>) -> Void

    init(unitID: String, completion: @escaping (Result<NativeAd, Error>) -> Void) {
        self.completion = completion
        let options = NativeAdViewAdOptions()
        options.preferredAdChoicesPosition = .topRightCorner
        loader = AdLoader(adUnitID: unitID, rootViewController: nil,
                          adTypes: [.native], options: [options])
        super.init()
        loader.delegate = self
    }

    func load() {
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        loader.load(request)
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        completion(.success(nativeAd))
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        #if DEBUG
        print("[FeedAds] Load: \(error.localizedDescription)")
        #endif
        completion(.failure(error))
    }
}
