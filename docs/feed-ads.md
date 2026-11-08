# Home feed ads

Home inserts an additional card after 6, 12, 18, … actual posts (feed positions 7, 14, 21, …), on regular iPhone and Duo. No posts are replaced. Group, profile, and tonight feeds do not receive ads. Google owns impressions, click handling, and AdChoices. Each card displays “Sponsored” using the same typography as post author names, with the advertiser below when supplied; it has no fake social reactions.

On expanded Duo, the left comments pane fades to the ambient background while an ad is the dominant visible feed item. The heading, thread, and composer are hidden together. Comments return when a normal post becomes dominant; existing drafts retain their original post and are not discarded. Ad visibility uses a distinct identity from its anchor post and the same boundary tolerance as regular post following.

## Current configuration

- **Admin → Feed Ads → Show feed ads** controls `app_config.feed_ads_enabled`, default **false**. Only the verified admin can update it; the database enforces this independently of the UI.
- **Off:** no sponsored or house-promo rows, and loaded ad slots are discarded. **On:** production builds request live ads; an app-owned Out Again promo fills each placement while waiting, on no fill, on consent failure, or while AdMob is not ready. The promo is outside Google's NativeAdView and generates no Google ad impressions/clicks.
- Release 2.2 build 7 includes production IDs and `OUTAGAIN_ADS_MODE=live`; its remote switch stays off until deliberately enabled. Debug uses Google's test unit when the same remote switch is on. Test mode is rejected in Release.
- Open signed-in apps refresh public configuration approximately every 10 seconds and on foreground. An off response removes cards immediately; offline clients retain their last known session setting until the next successful refresh. A new launch defaults off if configuration cannot be loaded.
- The SDK is not started by this integration until the remote switch is on and Google's UMP authorizes requests.
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

The November 8 replacement release adds remote control. Provider readiness and consent messages still need live dashboard verification before enabling paid ads.

## Remaining activation steps

AdMob is free to use: https://support.google.com/admob/answer/7356092

1. Version 2.2 now includes Marketing URL `https://cristianrebolloso.github.io/` and Support URL `https://cristianrebolloso.github.io/#support`. After Apple approves it, verify that the Developer Website link appears on the public listing.
2. Set up and publish applicable **European regulations** and **US state regulations** messages under AdMob **Privacy & messaging** for Out Again. Include a clear refusal choice and use the published privacy-policy URL. The IDFA explainer is not used by this integration. Verify UMP consent and the Settings privacy-options entry in Google's regional test modes.
3. In AdMob app settings, request verification again after the website link is public. The last check still showed **Requires review** with app verification incomplete; publishing the file alone does not establish AdMob approval. Review account/payment setup in the dashboard; payout, tax, and identity details were not accessed or submitted.
4. App Store privacy disclosures were updated and published November 8 for Google Mobile Ads/UMP, preserving existing social-feature disclosures. Advertising is declared in the age-rating form; the rating remains 18+. Keep disclosures current if SDK behavior changes.
5. After setup and verification are ready, use **Admin → Feed Ads → Show feed ads**. No new binary is needed to turn ads on/off after build 7 is approved and installed. Build 4 and older cannot be remotely enabled.
6. Validate consent accepted, declined, changed, and no-network/no-fill behavior using test ads before enabling paid ads broadly. Version 2.2 build 6 was submitted and installed on the connected Duo on November 8; build 7 supersedes it with the media-layout polish described below.

### App Store privacy preparation

The installed Google Mobile Ads 13.12.0 manifest and Google's disclosure guide identify coarse location (including IP-derived location), device identifiers, advertising data, product interactions, crash data, performance data, and other diagnostics. Advertising/analytics purposes apply according to the SDK documentation. The app never requests ATT, and both personalization and automatic device-location collection are disabled before SDK initialization. Keep the app's existing social-feature disclosures as well.

Confirm the final App Store answers against the archived app's combined privacy report and actual settings. Google declares SDK capabilities in its own bundled manifest; the app manifest does not erase those declarations. Avoid claiming that non-personalized ads collect no data.

Production configuration rejects sample IDs, missing IDs, malformed IDs, mismatched publisher IDs, and test mode in Release. A failed ad request does not block posts. The cache preloads the next placement, retains up to four creatives unless additional cards are currently visible, and reloads recycled/expired creatives when they are needed. Existing row height is retained during recycling so an offscreen cache eviction does not collapse the feed.

## Verification

```
xcrun swiftc OutAgain/Core/FeedAdPlacement.swift scripts/check-feed-ads.swift -o /tmp/check-feed-ads
/tmp/check-feed-ads
```

For the actual SDK and 30 local sample posts, launch a Debug build with `--duo-layout-preview --duo-continuity --feed-ads-preview`. Add `--duo-theme-wide-check` for the existing Duo layout check. The ad SDK uses Google's test unit; the app's social backend stays offline. Scroll past the sixth actual post. Use `--house-ads-preview` instead to keep Google offline and inspect the app-owned fallback.

On November 7, the Release simulator build and feed placement/configuration checks passed after connecting the production IDs and privacy controls. This was a compilation/configuration check, not a signed distribution archive or live-ad validation.

## Provider documentation

- Setup and SKAdNetwork list: https://developers.google.com/admob/ios/quick-start
- Native loading/test unit/caching: https://developers.google.com/admob/ios/native
- Native asset registration and attribution: https://developers.google.com/admob/ios/native/advanced
- Consent and privacy options: https://developers.google.com/admob/ios/privacy
- App Store data disclosure guidance: https://developers.google.com/admob/ios/privacy/data-disclosure

## November 8 switch validation

The public-Xcode 27.2 archive is version 2.2 build 6. Placement tests cover positions 7/14/21, pagination, deletion, incomplete pages, malformed config, and Release rejection of sample/test IDs. A transaction-scoped database check verified admin on/off, rejection of anonymous/member RPC calls and direct writes, and rejection of updates to unrelated config. The transaction was rolled back; the deployed switch remains `false`.

Migration `20261108070015_admin_feed_ads_switch.sql` narrows public config reads to app-safe keys. It excludes legacy server-only config values without changing server-side access. The new RPC is SECURITY INVOKER, with column-level UPDATE permission plus an admin-only RLS policy limited to this one key.

## Build 7 ad layout

The required SDK AdChoices control uses the supported bottom-right placement in an inset footer, away from the header, creative, and CTA. The NativeAdView remains inside the glass card with 16-point outer padding. Media height now follows the SDK aspect ratio without the old 360-point cap; portrait, square, and landscape images/video retain their full content without app-added side gutters. Missing aspect metadata falls back to image dimensions, then 3:2. SDK video controls, click registration, and impression measurement are unchanged. The source artwork may itself contain borders that the app cannot remove without cropping the advertisement.

Geometry checks cover six media ratios at four feed widths, the reported portrait regression, and invalid/missing metadata.
