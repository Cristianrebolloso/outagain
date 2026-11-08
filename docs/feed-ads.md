# Home feed ads

Home inserts an additional native ad after 10, 20, 30, … actual posts, on regular iPhone and Duo. No posts are replaced. Group, profile, and tonight feeds do not receive ads. Google owns impressions, click handling, and AdChoices. Each card displays “Sponsored” using the same typography as post author names, with the advertiser below when supplied; it has no fake social reactions.

On expanded Duo, the left comments pane fades to the ambient background while an ad is the dominant visible feed item. The heading, thread, and composer are hidden together. Comments return when a normal post becomes dominant; existing drafts retain their original post and are not discarded. Ad visibility uses a distinct identity from its anchor post and the same boundary tolerance as regular post following.

## Current configuration

- Debug: Google's native **test ads**, which do not earn money.
- Release: production IDs are installed, but ad serving remains **disabled** until the consent messages, store metadata, and verification below are complete. The SDK is not started by this integration until ads are enabled and Google's UMP authorizes requests.
- Local layout previews remain offline unless launched with `--feed-ads-preview`.
- Ads request non-personalized delivery (`npa=1` and publisher privacy personalization disabled), disable Google's publisher first-party identifier and automatic device-location collection, and do not request App Tracking Transparency authorization. No Out Again profile, photos, social graph, or post location is supplied to the ad SDK. Google may still infer approximate location from the network connection.
- UMP collects applicable privacy choices before ads load. Settings exposes “Ad privacy choices” when UMP requires it.

## Setup completed November 7, 2026

- AdMob app: Out Again (iOS), linked to App Store ID `6763454742`.
- App ID: `ca-app-pub-9977220370780276~1002055970`.
- Native advanced unit: **Home Feed Native**, `ca-app-pub-9977220370780276/3867892464`. Image and video are enabled, with Google's default optimized floor.
- Public website: https://cristianrebolloso.github.io/
- Publisher record verified over HTTPS: https://cristianrebolloso.github.io/app-ads.txt
- Published privacy policy: https://cristianrebolloso.github.io/privacy/ and the existing https://cristianrebolloso.github.io/outagain/privacy/ address.
- Website source: sibling `../outagain-website`, published in `Cristianrebolloso/cristianrebolloso.github.io`, commit `1d1b432`. Only the website files were pushed. Existing policy update in `Cristianrebolloso/outagain` is commit `c242f656beabef4388ed1077ab7aaf95195394f1`.
- Apple Developer account displayed its October 13, 2026 license agreement as accepted October 27, 2026. The older App Store Connect banner alone is not proof of an outstanding agreement.

Browser work was paused at the user's request. The following items are **not complete**.

## Remaining activation steps

AdMob is free to use: https://support.google.com/admob/answer/7356092

1. Set the App Store Connect **Marketing URL** (Developer Website) to `https://cristianrebolloso.github.io/`. The live listing currently has no seller/developer website. Keep the working privacy-policy URL or use `https://cristianrebolloso.github.io/privacy/`. Add `https://cristianrebolloso.github.io/#support` as the Support URL if appropriate. Submit the metadata through Apple's required version/review flow, and verify the Developer Website link appears publicly.
2. Set up and publish applicable **European regulations** and **US state regulations** messages under AdMob **Privacy & messaging** for Out Again. Include a clear refusal choice and use the published privacy-policy URL. The IDFA explainer is not used by this integration. Verify UMP consent and the Settings privacy-options entry in Google's regional test modes.
3. In AdMob app settings, request verification again after the website link is public. The last check still showed **Requires review** with app verification incomplete; publishing the file alone does not establish AdMob approval. Review account/payment setup in the dashboard; payout, tax, and identity details were not accessed or submitted.
4. Update App Store privacy disclosures to cover the actual Google Mobile Ads/UMP collection. See the preparation notes below and Google's disclosure guide. The published website policy is updated; App Store privacy answers remain unchanged.
5. After setup and verification are ready, set **Release** `OUTAGAIN_ADS_MODE` to `live`. The app and native unit IDs are already configured. Keep Debug on `test`.
6. Validate consent accepted, declined, changed, and no-network/no-fill behavior using test ads. Build a signed distribution archive, upload the next app version, and submit for App Review. No archive was uploaded and no update was submitted in this setup pass.

### App Store privacy preparation

The installed Google Mobile Ads 13.12.0 manifest and Google's disclosure guide identify coarse location (including IP-derived location), device identifiers, advertising data, product interactions, crash data, performance data, and other diagnostics. Advertising/analytics purposes apply according to the SDK documentation. The app never requests ATT, and both personalization and automatic device-location collection are disabled before SDK initialization. Keep the app's existing social-feature disclosures as well.

Confirm the final App Store answers against the archived app's combined privacy report and actual settings. Google declares SDK capabilities in its own bundled manifest; the app manifest does not erase those declarations. Avoid claiming that non-personalized ads collect no data.

Production configuration rejects sample IDs, missing IDs, malformed IDs, mismatched publisher IDs, and test mode in Release. A failed ad request does not block posts. The cache preloads the next placement, retains up to four creatives unless additional cards are currently visible, and reloads recycled/expired creatives when they are needed. Existing row height is retained during recycling so an offscreen cache eviction does not collapse the feed.

## Verification

```
xcrun swiftc OutAgain/Core/FeedAdPlacement.swift scripts/check-feed-ads.swift -o /tmp/check-feed-ads
/tmp/check-feed-ads
```

For the actual SDK and 30 local sample posts, launch a Debug build with `--duo-layout-preview --duo-continuity --feed-ads-preview`. Add `--duo-theme-wide-check` for the existing Duo layout check. The ad SDK uses Google's test unit; the app's social backend stays offline. Scroll past the tenth actual post.

On November 7, the Release simulator build and feed placement/configuration checks passed after connecting the production IDs and privacy controls. This was a compilation/configuration check, not a signed distribution archive or live-ad validation.

## Provider documentation

- Setup and SKAdNetwork list: https://developers.google.com/admob/ios/quick-start
- Native loading/test unit/caching: https://developers.google.com/admob/ios/native
- Native asset registration and attribution: https://developers.google.com/admob/ios/native/advanced
- Consent and privacy options: https://developers.google.com/admob/ios/privacy
- App Store data disclosure guidance: https://developers.google.com/admob/ios/privacy/data-disclosure
