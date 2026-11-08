# Out Again typography

Out Again is a social app for nights out with your friends. Type should feel personable, confident and easy to read over photos and colored light.

## Two voices

- **Cabinet Grotesk Bold**: page and section headings, post authors, profile names and large stats. Its distinctive stroke contrast gives the app character without adding decorative lettering to every sentence. Extrabold is reserved for the welcome brand hero.
- **General Sans**: comments, captions, notifications, search, forms, buttons, timestamps and tags. Use Regular for reading, Medium for supporting emphasis and Semibold for actions and row titles.

The app uses the original, unmodified OTF files from Indian Type Foundry's Fontshare. They are bundled locally in `Resources/Fonts` and registered through `OutAgainInfo.plist`; no network font loading is required. The accompanying `Fontshare-FFL.txt` permits app embedding. Source specimens:

- https://www.fontshare.com/fonts/cabinet-grotesk
- https://www.fontshare.com/fonts/general-sans
- https://www.fontshare.com/licenses/itf-ffl

## Tokens

All app-owned text uses `AppTypography` in `AppTheme.swift`.

| Use | Tokens | Base size / family |
| --- | --- | --- |
| Welcome identity | `brandHero`, `brandTitle`, `brandMoment` | 42 / 34 / 28 Cabinet |
| Page and sheet titles | `pageTitle`, `sheetTitle` | 30 / 24 Cabinet |
| Section titles | `sectionTitle`, `captureSectionTitle` | 22 / 26 Cabinet |
| Social names | `feedAuthor`, `profileName`, `profileNameLarge` | 26 / 26 / 36 Cabinet |
| Profile counts | `profileCountLarge` | 28 Cabinet |
| Reading | `body`, `bodyMedium`, `callout` | 17 / 17 / 16 General Sans |
| Rows | `rowTitle`, `rowSubtitle`, `rowSubtitleMedium` | 17 / 15 / 15 General Sans |
| Inputs | `formInput`, `searchInput`, `fieldLabel` | 17 / 15 / 15 General Sans |
| Names in captions | `feedCaptionAuthor` | 16 General Sans Semibold |
| Usernames | `username`, `usernameCompact` | 15 / 12 General Sans |
| Controls | `button`, `controlLabel`, `actionLabel`, `toolbarAction` | 15 / 15 / 17 / 17 General Sans Semibold |
| Secondary text | `footnote`, `footnoteMedium`, `caption`, `captionMedium` | 13 / 13 / 12 / 12 General Sans |
| Social metadata | `metadata`, `metadataEmphasis`, `chip`, `chipEmphasis` | 12 General Sans |
| Pills | `pill`, `pillMedium`, `pillSmall` | 14 / 14 / 13 General Sans |
| Small badges | `badge`, `badgeStrong`, `badgeNumber`, `chipSmall`, `caption2Emphasis` | 10–12 General Sans |
| Timers | `timer` | 12 General Sans, tabular figures |
| Stats | `statNumber`, `statCompact`, `statCard`, `statSummary`, `statTotal`, `statFeature`, `statHero` | 22 / 34 / 38 / 40 / 44 / 46 / 70 Cabinet |

## Implementation rules

- Use semantic tokens, not local `.system` fonts or new custom font names.
- Each custom font scales relative to an appropriate Dynamic Type text style. Do not replace it with `fixedSize` font construction.
- Names can wrap when the layout allows it. Keep small timestamps and labels subordinate to people and photos.
- Keep SF Symbols and emoji on system font sizing. Native tab bar labels and system-owned alerts retain system typography and behavior.
- Native navigation titles receive General Sans (inline) and Cabinet Grotesk (large) through text appearance attributes only. Do not replace native bars or alter their glass styling for typography.
- Font resources are original licensed files. Do not edit, subset, convert, or publish them as a downloadable font library.

## Default background

`StandardNightlifeBackdrop` draws six separate blue, rose, mint, violet, pink and green light pools over near-black. Each has its own radial fade and uses screen blending, so lights remain saturated rather than turning brown where they overlap. Positions and radii scale with the window, including both Duo orientations. Other selected themes retain their own palettes.
