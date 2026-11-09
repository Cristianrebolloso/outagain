# Friends and night sharing

Implemented November 8, 2026. Out Again remains focused on posting drinks,
tracking drink tags, and seeing friends' nights.

## Invitations

People and profile onboarding offer Invite friends (native share sheet / QR)
and Use code. A server-issued link points to the published landing page:
`https://cristianrebolloso.github.io/invite/?code=<token>`.

Opening a link only previews it. Explicit acceptance sends a friend request,
accepts a reciprocal request, or recognizes an existing friendship. Group invites
also join that group, but do not grant access to private posts before friendship
acceptance. Only group creators can issue group invites. Groups can be created
before friends install the app.

Friend links expire after 30 days; group links expire at the creation night's
next 7 a.m. in the validated creator timezone. Blocked/banned accounts and expired
codes cannot resolve or accept invites. Codes are unguessable and not enumerable
through the Data API. No new analytics or contact-address-book access was added.

Pending links survive sign-in/profile setup. Invites wait for camera/notification
presentations to close. A dismissed invite is not automatically reopened after
posting; People retains a Continue invite action. New links supersede old preview
requests, and an old acceptance cannot clear a newer pending link.

Universal links use `applinks:cristianrebolloso.github.io`, with AASA hosted in the
website repo `../outagain-website`. The landing page provides an explicit custom
URL open action and copy/paste fallback after installation. iOS does not promise
that a web invite is automatically retained through a first App Store install;
users reopen the link or paste it after installing.

## Other changes

- Compact Posted tonight strip, Post action, and Tonight / Earlier feed boundaries.
- Drink Totals immediately after the profile's Nights Posted Out hero.
- Same-post Activity interactions on the same day expand as a bundle, preserving
  every original timestamp, unread flag, exact comment link, and dismiss action.
- Night recap: select 1–6 photos, review a 1080×1920 collage, then Share or Save.
  Selected drink labels/date remain; names, captions, locations and source image
  GPS metadata are not added to the exported collage.

## Backend verification

Migrations:
- `20261109034848_friend_discovery_and_share_invites.sql`
- `20261109040111_align_group_invites_to_night_end.sql`

Corrected a profile RLS predicate which bound an unqualified `id` to the friendship
row instead of the profile, hiding pending counterparts in the direct-table
fallback. Current RPC hydration and the fallback were checked separately. This
confirms a real failure path, not the cause of an unidentified user's old report.

Authenticated transactional tests verify search/name whitespace/@handles,
friendship consent and retries, pending counterpart visibility, blocks/bans,
privacy, solo groups, invite expiration, timezone validation and DST boundaries.
All 25 eligible existing profiles were found by exact username and uppercase
@handle in the read-only live audit. Synthetic fixtures were rolled back.

Swift tests cover client RPC serialization/decoding, pending-invite routing,
recap export/selection, Activity grouping, and existing purchase/offline/reaction
behavior. No synthetic photos or messages were sent to real users.
