# Supabase backend for Out Again

Out Again is a real Supabase client only. There is no offline or in-memory
fallback — if `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` aren't set in
Info.plist, the app renders a configuration-error screen instead of booting.
This is intentional: every byte the user sees is guaranteed to have come
from the backend.

For step-by-step first-launch instructions (new Supabase project, Info.plist
keys, seeding the developer test account that makes the `1`/`1` shortcut
work), see `../DEPLOY.md`.

## App configuration keys

Set these in the iOS target's Info.plist (or as build settings resolved into
Info.plist):

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
- `202604230002_profile_contact_match.sql` — contact-based friend discovery.
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
  columns locked down; contact matching moved behind a narrow RPC.
- `202604290005_feed_delta_and_engagement_counts.sql` — exact post engagement
  count RPCs plus lightweight feed-delta polling RPC.
- `202604290007_content_reports_delete_account_and_storage_tuning.sql` —
  moderation queue table, GIF comment bucket support, and account-deletion
  backend support.

## Edge functions

`supabase/functions/notify-activity/index.ts` receives notification insert
payloads from the `dispatch_notification_push` trigger, sends APNs pushes,
and writes the final delivery status back to `public.push_attempts`. Deploy
with `supabase functions deploy notify-activity` and configure the Postgres
`app.settings.*` values described in DEPLOY.md.

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

For now, moderation is intentionally simple and free: reports land in the
`content_reports` table. Use Supabase Dashboard → Table Editor to review new
rows, change `status`, and add `moderator_note` when you resolve a report.
