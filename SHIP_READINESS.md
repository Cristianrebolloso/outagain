# Out Again 2.2 Production Launch Checklist

**Date:** 2026-05-18
**Scope:** Out Again iOS app, widget extension, Supabase schema, edge functions, push delivery, privacy, reports, and admin moderation.

Out Again 2.2 is the production release line. The app should be treated as a
real social product with real users, real content, real reports, and real
operational responsibilities.

## Launch Gate

Ship only from a clean Release build pointed at the production Supabase
project. Before submission, confirm each item below against the live backend,
not just local code.

| Area | Production requirement |
| --- | --- |
| Auth | Email/password and Sign in with Apple work against the live project. |
| Profiles | `auth.users` creates/recovers `profiles`; reserved usernames are enforced by the database. |
| Privacy | Friend-only RLS is applied for profiles, posts, comments, reactions, and tagged posts. |
| Admin | `@admin` can review reports, see all moderation-relevant users/posts, delete content, and ban users. |
| Safety | Users can report posts/comments/users, block users, delete their own account, and remove their own content. |
| Push | APNs secrets, Vault service-role secret, `notify-activity`, and `push_attempts` diagnostics are live. |
| Storage | `avatars` and `moments` buckets exist with expected RLS, MIME limits, and CDN settings. |
| App Review | Review/demo accounts and seeded review data remain available so Apple can exercise the social graph. |
| Compliance | Privacy manifest, hosted privacy policy, account deletion, and moderation flows match App Store metadata. |
| Operations | Production crash/error monitoring and a report-review routine are in place. |

## Required Live Checks

1. Run `supabase db push` against the production project and verify every
   migration under `supabase/migrations/` is applied.
2. Deploy `notify-activity` and `delete-account`; set APNs secrets and the
   `supabase_service_role_key` Vault secret.
3. Create and onboard the `@admin` moderation account.
4. Keep App Review/demo accounts provisioned and working.
5. Perform a Release-device smoke test:
   sign up, sign in, create a profile, add/accept a friend request, create a
   post, comment, react, tag a friend, report content, delete content, block a
   user, delete an account, and review/delete/ban from `@admin`.
6. Trigger a self-test notification and confirm `public.push_attempts` records
   `delivered` or a clearly understood APNs response.
7. Verify a fresh install opens the production backend, not an unconfigured placeholder.
8. Archive the Release build and submit only after the archive succeeds cleanly.

## Production Notes

- Debug-only shortcuts are allowed for local development, but Release builds
  must use normal authentication paths.
- The anon/publishable Supabase key can live in the app bundle; the service-role
  key must remain server-side only.
- Seeded App Review data should remain isolated to review/demo accounts.
- Any production issue involving reports, bans, account deletion, push delivery,
  or RLS visibility is launch-critical and should be handled before expansion.
