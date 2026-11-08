# Supabase backend for Out Again

Out Again is a real Supabase client only. There is no offline or in-memory
backend fallback: every byte the user sees is loaded from Supabase. The app
ships with production publishable defaults and can also override them through
Info.plist/build settings. Keep the service-role key server-side only.

For step-by-step production launch instructions, including App Review/admin
account setup and edge-function deployment, see `../DEPLOY.md`.

## Reliability verification — October 28, 2026

Verified against production project `xissvzlusznqpxvwnwpu`. These database fixes
are deployed; the Swift changes below require distributing the updated app.

- Search accepts two or more characters, names, username prefixes, and `@handles`.
  Exact usernames rank first. Search exposes public identity fields only and
  excludes blocked/banned people. The older username RPC remains compatible.
- Friend requests require the recipient's acceptance. A blocked person cannot
  remove somebody else's block, and retrying acceptance sends only one alert.
- Ban checks apply to the intended account. The former unqualified SQL argument
  could treat every account as banned if any banned-user row existed. There were
  no banned accounts in production during this check; regression fixtures proved
  the bug and fix without leaving a ban behind.
- Internal account-email hashes are unavailable to client roles; four profile
  trigger functions now have fixed function search paths.
- Updated iOS posting uses a stable draft ID and deterministic image path.
  Duplicate taps/retries cannot create a second row for the same draft. A lost
  response is reconciled against the saved post. Success uses the server's actual
  ID/timestamp. Failed posting keeps the photo and details available for retry
  while the composer remains open. This is in-memory recovery, not an offline
  queue or persistence across force-quit.

Applied migrations: `20261028202747_friend_search_and_post_reliability`,
`20261028202908_isolate_account_ban_checks`,
`20261028204133_harden_internal_profile_helpers`, and
`20261028204230_deduplicate_friend_accept_notifications`.

Verification passed:

- Live authenticated API: exact/partial username, case/`@` normalization, display
  name, feed reads, existing image access, and a generated Storage image's
  upload/read/delete round trip. Anonymous search was denied. Twelve requests
  had a 366 ms median and 2,384 ms maximum; this is a smoke test, not a load test.
- `tests/friend_search_and_post_reliability.sql`: search, blocks/bans, consent,
  notification deduplication, photo-only posts, idempotency, valid/invalid tags,
  private visibility, comments/reactions, owner deletion, and dependent cleanup.
- `tests/local_feed_friend_radius.sql`, `tests/local_feed_and_recaps.sql`,
  `tests/notification_preferences.sql`, and `tests/admin_push_announcements.sql`.
- All 27 sign-in and notification Edge Function tests.
- Debug simulator checks through the actual Swift client/store: delayed search,
  upload timeouts, a committed post with a lost response, empty insert responses,
  duplicate taps, failed-post draft recovery, and successful retry. UI flow checks
  also covered capture review, Retake, and retained photo/details after failure.
- Debug simulator and Release device builds; `git diff --check`.

All SQL fixtures ran inside rolled-back transactions. The live probe created no
posts or friend requests; its generated image was deleted. No test user, post,
or media was left behind. At inspection, there were no missing referenced post
images/avatars, duplicate accepted friend pairs, deadlocks, or waiting queries.
The sampled prior 24-hour API log contained no 5xx responses.

Repeat the Edge Function checks with:

```sh
node --test supabase/functions/sign-in/index.test.mjs supabase/functions/notify-activity/index.test.mjs
```

For the live API smoke test, use `python3 scripts/check-live-api.py --session-plist
<simulator-app-preferences.plist>` with an existing unexpired signed-in simulator
session. It never prints tokens or signs in/refreshes the session. On this Mac,
set `SSL_CERT_FILE=/etc/ssl/cert.pem` for Python's system trust store.

Run SQL files with `BEGIN` / `ROLLBACK`; the friend/post reliability and Local
friend-radius files include their own transaction. Debug launch arguments
`--duo-layout-preview --backend-reliability-checks` run the isolated Swift fault
checks, and `--duo-layout-preview --duo-review --post-review-flow-checks` run the
review-flow checks. These use fixtures and never publish to production.

This is functional verification, not a full security audit, load/SLA guarantee,
or proof of physical-device camera/push behavior. Existing advisor follow-ups
remain: [RLS/index performance](https://supabase.com/docs/guides/database/database-linter?lint=0003_auth_rls_initplan),
[privileged RPC grant review](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable),
[extension placement](https://supabase.com/docs/guides/database/database-linter?lint=0014_extension_in_public),
and [leaked-password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## App configuration keys

These values are already set for the current production target. Override them
through the iOS target's Info.plist or build settings only when pointing a
build at a different Supabase project:

- `SUPABASE_URL` — e.g. `https://<project-ref>.supabase.co`
- `SUPABASE_PUBLISHABLE_KEY` — the anon/publishable key from Project Settings → API
- `SUPABASE_STORAGE_BUCKET` — defaults to `moments`
- `SUPABASE_AVATAR_BUCKET` — defaults to `avatars`
- `OUTAGAIN_INVITE_BASE_URL` — defaults to `https://outagain.app/invite`

## Apple sign-in

1. Enable the Apple provider in Supabase Auth (Project Settings → Auth → Providers → Apple).
2. Add the Sign in with Apple capability to the iOS target and App ID.
3. The app prepares a nonce, captures the returned identity token, and
   exchanges it with `POST /auth/v1/token?grant_type=id_token`.

## Database

Apply migrations in order from `supabase/migrations/`. The current set:

- `202604230001_initial_social_schema.sql` — profiles, friendships, posts,
  comments, reactions, notifications, devices; public `avatars` and `moments`
  storage buckets; initial RLS; activity triggers.
- `202604230003_hardening_and_profile_bootstrap.sql` — `auth.users` →
  `profiles` bootstrap trigger, server-side reserved-username table, extra
  constraint hardening.
- `202604230004_friendship_workflow_and_rls.sql` — pending / accepted /
  blocked states, symmetric reciprocity on insert, friends-only RLS on
  posts/comments/reactions/profiles.
- `202604230005_comment_media.sql` — comment attachments.
- `202604230006_notification_fanout.sql` — trigger-backed fanout from
  `notifications` into the APNs edge function.
- `202604230010_push_delivery_receipts.sql` — APNs delivery receipts in
  `push_attempts` for real push diagnostics.
- `202604290004_profile_privacy_and_contact_match_rpc.sql` — private profile
  columns locked down.
- `202604290005_feed_delta_and_engagement_counts.sql` — exact post engagement
  count RPCs plus lightweight feed-delta polling RPC.
- `202604290007_content_reports_delete_account_and_storage_tuning.sql` —
  moderation queue table, GIF comment bucket support, and account-deletion
  backend support.
- `202605150002_remove_contact_matching.sql` — removes the deprecated contacts
  discovery RPC and email-fingerprint column.
- `202605160001_profile_verification.sql` — server-driven `profiles.is_verified`
  badges with admin-only verification updates.
- `202605160002_app_announcements.sql` — server-driven launch announcements
  with one-time dismissal receipts and optional username targeting.
- `202605170001_latest_app_announcement_watermark.sql` — latest-only
  announcement delivery and a per-user onboarding watermark.
- `202605170002_admin_moderation_controls.sql` — @admin-only moderation RPCs
  for ban/unban, content purging, report resolution, and banned-account write
  blocking.
- `202605170002_admin_reports.sql` — in-app moderation queue for `@admin`
  with report review, post/comment deletion, and user bans.
- `202605180004_app_maintenance_mode.sql` — public `app_config` rows for
  runtime feature/config flags, including a remote maintenance-mode screen.

## Maintenance mode

Use maintenance mode when you need to pause the app without shipping an update.
The app reads `public.app_config` at launch, on foreground, and once per
foreground polling minute. When `maintenance_mode_enabled` is true, users see a
black unavailable screen and the app skips the heavier bootstrap/delta fetches.

Turn it on from the Supabase SQL editor:

```sql
insert into public.app_config (key, value)
values
  ('maintenance_mode_enabled', 'true'),
  ('maintenance_title', 'Out Again is currently unavailable'),
  ('maintenance_message', 'We''re doing some quick maintenance. Please check back soon.')
on conflict (key) do update
set value = excluded.value;
```

Turn it back off:

```sql
update public.app_config
set value = 'false'
where key = 'maintenance_mode_enabled';
```

## App announcements

Use app announcements for launch-time news or one-off messages that should
appear inside the app the next time a user opens it. Once the viewer taps
Dismiss, `app_announcement_receipts` prevents that announcement from showing
for that account again.

Only the newest eligible announcement is shown. Publishing a new announcement
through `create_app_announcement` deactivates older active announcements for the
same audience, and the fetch RPC suppresses older unseen messages even if they
were inserted manually. New accounts start their announcement eligibility when
they complete profile onboarding, so they are not shown messages that already
existed when they joined.

Publish to everyone from the Supabase SQL editor:

```sql
select public.create_app_announcement(
  'Weekend update',
  'New profile stats are live. Go see your longest bender.'
);
```

Publish only to specific usernames:

```sql
select public.create_app_announcement(
  'Cristian only',
  'This message only shows for @cristian.',
  array['cristian']
);
```

You can also schedule or expire one:

```sql
select public.create_app_announcement(
  'Tonight only',
  'A short-lived message.',
  null,
  now(),
  now() + interval '12 hours'
);
```

## Edge functions

`supabase/functions/notify-activity/index.ts` receives notification insert
payloads from the `dispatch_notification_push` trigger, sends APNs pushes,
and writes the final delivery status back to `public.push_attempts`. Deploy
with `supabase functions deploy notify-activity` and store the trigger's
service-role key in Supabase Vault as described in DEPLOY.md.

`supabase/functions/delete-account/index.ts` verifies the caller's JWT,
deletes the Auth user with the service role, and best-effort removes avatar
and post/comment media objects left in Storage. Deploy it with
`supabase functions deploy delete-account`.

Required function secrets (set via `supabase secrets set ...`):

- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_BUNDLE_ID` — `com.cristian.OutAgain` (or your actual bundle ID)
- `APNS_KEY_P8` — the `.p8` contents, including the BEGIN/END lines

## Developer test account

The app has a Debug-only `1`/`1` shortcut, but it now resolves only from
local machine config. Set `OUTAGAIN_DEV_SHORTCUT_EMAIL` and
`OUTAGAIN_DEV_SHORTCUT_PASSWORD` as scheme environment variables or local
Info.plist keys on your machine, then provision that matching account in
`auth.users`. There is no server-side allowlist; the shortcut is just the
app filling in your local dev credentials for you.

## Reviewing reports

Reports land in the `content_reports` table. The `@admin` account can review
them in-app from the Reports tab and call admin-only RPCs to mark reports
reviewed, delete reported posts/comments, or ban a reported user.


## Custom announcement pushes

In the updated app, open **Admin → Notifications**, choose **In-App**, **Push**,
or **Both**, enter a title and message, select the audience, and confirm the send.
Push titles allow 100 Unicode characters and messages allow 500. Friday/Saturday
reminders are manual sends; this feature does not schedule recurring broadcasts.

**Settings → Notifications → Announcements** saves an account-wide push preference.
It defaults to enabled for existing accounts. The server checks the preference
when queueing a broadcast and again before APNs delivery. Turning it off leaves
in-app launch pop-ups and social notifications unchanged. iOS notification
permission is also required for banners and Lock Screen alerts.

The existing `notify-activity` function and APNs secrets handle delivery.
`admin_publish_announcement` requires the admin account; its caller supplies a
stable request UUID so retrying the same send does not queue it twice. Public
admin RPCs delegate to privileged functions in the non-exposed `private` schema.
Push-only announcements are excluded from the launch-pop-up RPC, including for
older app versions. Delivery history distinguishes queued accounts, devices
accepted by Apple, pending, skipped, and failed attempts. Apple acceptance does
not prove that a person saw a notification. Push alerts expire after 24 hours;
already delivered pushes cannot be recalled by removing a pop-up.

Deployed backend migrations: `20261027191746_admin_push_announcements.sql` and
`20261027192051_private_announcement_admin_functions.sql`, plus
`20261027193437_default_on_notification_categories.sql`. The new app controls
require distributing this app build; backend deployment does not update installed
apps.

Verification: `node --test supabase/functions/notify-activity/index.test.mjs`
uses mocked APNs and checks authentication, opt-outs, failure handling, payloads,
and device retirement. Run `supabase/tests/admin_push_announcements.sql` only
inside `BEGIN; ... ROLLBACK;` to test real admin authorization, RLS, audience
selection, retries, and pop-up behavior without committing test notifications or
pg_net requests. No test broadcast was sent to real users during implementation.


## Default-on notification preferences

All push categories are enabled unless the account explicitly opts out:
Friend requests (including acceptances), Reactions (including comment likes),
Comments (including photo replies and comment mentions), Tags & other activity
(including group invitations and verification), and Announcements. Missing rows
use enabled defaults. Every send rechecks its own category; lookup errors fail
closed. Saving a switch changes only that column. Existing local social opt-outs
migrate once when the updated app opens; existing server opt-outs stay off.

Live Activities also default on and start after posting, with no separate app
opt-in prompt. Settings can disable them and end an active Live Activity. Old
unanswered/temporary opt-in prompts migrate to on; deliberate Settings opt-outs
remain off. Preferences are cached per account, including across sign-out. Live
Activities are device-local; push preferences sync across the account. Apple's
notification permission and Live Activities system settings remain authoritative.

Preference checks:

```sh
xcrun swiftc OutAgain/Core/NotificationPreferences.swift OutAgain/Services/NotificationPreferencePayload.swift scripts/check-notification-preferences.swift -o /tmp/check-notification-preferences
/tmp/check-notification-preferences
node --test supabase/functions/notify-activity/index.test.mjs
```

Run `supabase/tests/notification_preferences.sql` in `BEGIN; ... ROLLBACK;` to
check database defaults, partial updates, and account isolation. These checks
never commit real users' preference changes or send test pushes.


### Local feed and night recaps (October 27, 2026)

Home now offers Friends, then Local. Each new post defaults to the existing friends/tagged-friends audience; `is_shared_locally` is an explicit opt-in. Local reads require a fresh private discovery context, exclude blocked/banned accounts, and return posts from the last 48 hours within about 35 miles. Public post coordinates are rounded before storage and venue coordinates/names are removed for Local posts. Existing posts were not opted in.

The Friends/Local switcher appears only when the current Local results contain an eligible post. Home checks for Local content even while Friends is selected or the switcher is hidden. A friend's opted-in post within 35 miles appears in both feeds; friendship does not override the Local radius. If Local loses its last eligible post, Home returns to Friends and removes the switcher. Last-night recap access remains independent of Local availability.

`supabase/tests/local_feed_friend_radius.sql` includes its own rollback and checks nearby friends in both audiences, private/far friends excluded from Local, the 35-mile boundary, expiry, and nonfriend profile privacy. Reading a Local post does not unlock its author's private posts, full profile row, or friends list; the app also keeps the profile grid, tagged posts, and stats behind the friendship check. Public identity and counts remain available for discovery. The Debug `--duo-layout-preview --discovery-checks` fixture verifies picker eligibility, fallback, and the private-profile gate using the actual app store.

Migration `20261027213211_local_feed_thirty_five_mile_radius.sql` is deployed. Local uses a 35-mile radius (56,327.04 meters) so suburban viewers can see activity downtown. The Local SQL checks verify access at 34.99 miles, exclusion at 35.01 miles, feed/direct-read visibility on either side of the boundary, and downtown Dallas visibility from representative Plano and north Frisco locations.

Migrations `20261027210359_local_feed_and_night_recaps.sql` and `20261027211911_local_feed_timestamp_bounds.sql` are deployed. The updated `notify-activity` handler (version 13) passes photo/comment and recap destinations through APNs. Only clients registering a discovery context qualify for the new recap notification kind. The scheduled job checks every 15 minutes, sends at most one reminder per account/night between 11am and 1pm in the account's time zone, and requires relevant photos (three photos, or a tagged photo). Group members need not post. Recap opt-outs, already-viewed recaps, and accounts that have returned after 7am are skipped. Local-only strangers' posts do not create personal recap reminders.

Validation: run `supabase/tests/local_feed_and_recaps.sql` between `BEGIN` and `ROLLBACK` through an administrative SQL connection. The fixtures are synthetic and rollback prevents queued `pg_net` pushes from being sent. The test covers distance, audience, blocks, stale location, future/old posts, equal-date pagination, comments/reactions/reporting, nonposter group recaps, duplicate alerts, opt-outs, and already-active recipients. Run `node --test supabase/functions/notify-activity/index.test.mjs` for the notification handler. Simulator checks covered iPhone, closed/open Duo, recap-to-photo navigation, Local opt-in, and requiring location before posting. Physical-device APNs receipt and app distribution remain separate release checks.
