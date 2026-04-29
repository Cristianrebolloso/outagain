# OutAgain — Ship-Readiness Audit

**Date:** 2026-04-23
**Scope:** OutAgain iOS app + Supabase backend (`supabase/migrations`, `supabase/functions`), static review only.
**Verdict:** Closed-alpha ready. Public launch requires roughly two to four weeks of focused backend work, concentrated in five areas. The architecture is sound; the plumbing is incomplete in predictable, fixable ways.

---

## How to read this document

Findings are bucketed by severity. **P0** blocks public launch. **P1** causes user-visible bugs or abuse risk and should block the public launch on principle. **P2** is polish and scale. Within each bucket I list the problem, the concrete change, and the file(s) to touch. Line numbers are included when useful; they were validated against the actual files, not taken on faith.

---

## One-page summary

| Feature area | Works today | Ships as-is | Primary gap |
|---|---|---|---|
| Sign in with Apple | Yes | Yes, with one trigger to add | No `auth.users → profiles` bootstrap trigger; a crash between auth and profile create leaves an orphan user |
| Username uniqueness | Yes | Yes | Reserved-name list lives only on the client; a motivated attacker can claim `admin` |
| Profile edit (name, pfp) | Yes | Mostly | No cache-busting on avatar URL; no realtime push, so friends see changes only on next refresh |
| Posts / reactions / comments | Yes | **No — schema bug** | `comments.id` is a primary key with no default; a client that forgets to set it fails with a DB error |
| Friends | Partial | **No** | Flow auto-accepts; no pending / reject / block / unfriend path, no DELETE policy on `friendships` |
| In-app notifications | Yes | Yes | Fine for now |
| Push notifications (APNs) | **No** | **No** | Device table exists; nothing registers a token; edge function is a stub |
| Deployment | Unknown | **No** | No `config.toml`, no linked project ref, no seed data — I cannot confirm migrations were ever applied |

Five P0 blockers, detailed below.

---

## P0 — Blocks public launch

### 1. `comments.id` has no default UUID

**Evidence:** `supabase/migrations/202604230001_initial_social_schema.sql:65-73`. Every other table in the migration uses `id uuid primary key default gen_random_uuid()` (friendships line 30, posts line 40, reactions line 78, notifications line 89, devices line 104). Comments alone is `id uuid primary key,` — no default. Today the Swift client supplies a client-generated UUID in `AppStore+Posting.swift`, so the `INSERT` succeeds. The day anyone writes a server-side path, a webhook, or an SDK call that omits `id`, every comment insert 500s.

**Fix:** one-line migration.
```sql
alter table public.comments alter column id set default gen_random_uuid();
```
Ship as `202604230003_comments_default_id.sql`. Zero-risk change.

### 2. Friendship workflow is missing (P0 because the social graph is the product)

**Evidence:** `SupabaseSocialBackendClient.swift` hardcodes `status: "accepted"` on insert. The schema supports `pending | accepted | blocked` (migration line 29-37) but the app never issues `pending`, never transitions state, and has no UI for incoming requests, reject, block, or unfriend. There is also no `DELETE` policy on `friendships` — checked: the policies at lines 232, 239, 246 cover SELECT / INSERT / UPDATE only. You cannot unfriend without server-side intervention.

**Impact:** a user can add anyone without consent and instantly see their feed. This is both a trust problem and a probable App Store review flag.

**Fix** — this is real work, not a one-liner:
1. Change client default to `status = 'pending'` on `addFriend`.
2. Add `AcceptFriendRequest` / `RejectFriendRequest` methods that `PATCH` the row.
3. Add a DELETE RLS policy on `friendships` scoped to `auth.uid() IN (user_id, friend_id)`.
4. Feed/profile visibility RLS must check `status = 'accepted'` — today posts are world-readable by all authenticated users (migration lines 254-259), meaning a non-friend who knows the API can scrape the entire feed. The app filters in memory; that is not security.
5. Add in-app notification on new pending request (the existing `notifications` table supports `kind`, so use it).

**Files to touch:** `supabase/migrations/202604230003_*.sql` (new), `Services/SocialBackendClient.swift` (new methods), `Services/SupabaseSocialBackendClient.swift`, `Core/AppStore+Friends.swift`, a new `Features/Friends/IncomingRequestsView.swift`.

### 3. Posts are world-readable

**Evidence:** migration line 254-259 grants `SELECT` on `posts` to `authenticated` with no predicate. Same for `comments` and `reactions`. The app hides non-friends' content in memory (`AppStore.swift` `scopedPosts`). Anyone with a valid session token and a REST client sees everything.

**Fix:** tighten RLS. This is where you earn the "looks like a world-class pro built it" qualifier. Two reasonable patterns:

(a) **Predicate on friendship row.** Cheaper to write; more expensive per-query.
```sql
create policy "friends can read posts" on public.posts for select to authenticated
using (
  author_id = auth.uid()
  or exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.user_id = auth.uid() and f.friend_id = posts.author_id)
        or (f.friend_id = auth.uid() and f.user_id = posts.author_id))
  )
);
```
Index `friendships(user_id, friend_id, status)` and `friendships(friend_id, user_id, status)` to keep this fast.

(b) **Materialize an `accepted_friendships` symmetric view** or a denormalized `visible_to_user_id` column written by a trigger. Better at scale; more moving parts. Do (a) at v1, migrate to (b) if the feed query gets slow.

Apply the same pattern to `comments` and `reactions`, gating on the parent post's visibility. Apply to `profiles` too — today any authenticated user can dump the profile table.

### 4. Push notifications are not wired

**Evidence:** `supabase/functions/notify-activity/index.ts` is a stub that echoes the payload with a TODO. I grepped the entire Swift tree for `deviceToken`, `registerForRemoteNotifications`, and `apns` — no real matches. The `devices` table (migration line 103-110) is schema-only; nothing ever writes to it. The notification triggers insert into the in-app `notifications` table but never reach APNs.

**Fix** — ordered, each step independently verifiable:
1. In `OutAgainApp.swift`, adopt `UIApplicationDelegateAdaptor`, request notification authorization, call `UIApplication.shared.registerForRemoteNotifications()`, and in `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` upsert `{user_id, apns_token, environment}` to the `devices` table.
2. Provision an APNs auth key in Apple Developer, store it as a Supabase secret (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_TOPIC`).
3. Finish `notify-activity/index.ts`: read recipient's `devices` rows, sign a JWT for APNs, POST to `api.push.apple.com` (prod) or `api.sandbox.push.apple.com` (dev) per row, mark invalid tokens stale.
4. In the migration's `notify_on_reaction` / `notify_on_comment` triggers, `pg_net` a POST to the edge function, or — better — change the trigger to insert into a `push_queue` table and have the edge function run on a schedule. The queue pattern is more robust under load and lets you retry.
5. Add a friend-request kind and fan-out.

**Order-of-magnitude effort:** one engineer, four to six days end-to-end including TestFlight validation.

### 5. Deployment state is unknown

**Evidence:** no `supabase/config.toml`, no `.env`, no `.supabase/` directory, no seed SQL. I cannot tell whether a live Supabase project exists, whether the two migrations are applied, or whether the Apple provider is enabled in the dashboard. The Swift client falls back to a mock backend (`MockSocialBackendClient.swift`) when `SupabaseEnvironment` can't read Info.plist — so the app "works" locally without any of this being real.

**What you should do before any other fix:**
1. Confirm whether a Supabase project exists for OutAgain. If yes, share its ref; if no, create one.
2. `supabase link --project-ref <ref>`, then `supabase db push` to apply both migrations.
3. In the dashboard, Auth → Providers → Apple → enable, paste the Services ID, Team ID, Key ID, and P8.
4. Create a `.env.example` at the repo root listing every required value (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, invite base URL, APNs keys) so the next engineer doesn't reverse-engineer this.
5. Add a `supabase/seed.sql` with a few test accounts and a handful of posts so QA has a deterministic starting point.

Until this is done, nothing in this audit is actually deployed to anyone. This is also the step most likely to surface latent bugs — a schema that lints locally can still fail to push because of privilege mismatches or extension ordering.

---

## P1 — Should block launch on principle

### Profile row is not auto-created on Apple sign-in

If the user completes Sign in with Apple but the app crashes, loses network, or the user force-quits before `createProfile` runs, `auth.users` has a row and `public.profiles` does not. On next launch, `fetchCurrentProfile()` returns nil and the client silently falls into an empty bootstrap state, with no path back except to reinstall.

**Fix:** a DB trigger in a new migration.
```sql
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, display_name)
  values (new.id, 'user_' || substr(new.id::text, 1, 8), null)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_auth_user();
```
Then treat the client's username/display-name step as an *update*, not an insert. This also lets you recover stranded users who already slipped through.

### Reserved-username enforcement lives only on the client

`admin`, `support`, `outagain`, `moderator` are guarded in `SupabaseSocialBackendClient.swift` and `MockSocialBackendClient.swift`. Anyone bypassing the app sets username = 'admin' freely. Move this into the DB as a `reserved_usernames` table plus a `check (not exists (...))` pattern in a BEFORE INSERT/UPDATE trigger on `profiles`. Bonus: editable without a client release.

### Avatar URL cache-busting

`avatar_path` is deterministic (`users/{uid}/avatar.jpg`), which is good for storage hygiene but means Cloudflare/Supabase edge caches and SDWebImage caches all hold the old image. After a PFP change, friends see the stale image for up to an hour.

**Fix:** add `avatar_version integer not null default 1` to `profiles`, bump it on every upload, and append `?v=<n>` to the URL in `storageObjectURL(...)`. One-line change on both sides.

### Reaction toggle race

In `AppStore+Posting.swift` the add-then-remove path reads the old reaction snapshot. Low real-world impact; a `Task` serialization on a per-post actor cleans it up. Park it until after launch unless QA sees it.

### No post/comment deletion

Users cannot delete their own content. This is a DSA / App Store expectation. Add DELETE RLS policies scoped to `auth.uid() = author_id` on `posts` and `comments`, expose a `deletePost(id:)` / `deleteComment(id:)` on the backend client, and add the UI affordance. Include soft-delete (`deleted_at timestamptz`) if you want an "undo" window.

### Feed fetches 80 rows unfiltered

`fetchFeedPosts(limit: 80)` does `WHERE true ORDER BY created_at DESC`. Once RLS is tightened (P0 #3), this becomes correct but inefficient — RLS will filter after the sort. Add `WHERE author_id IN (...)` at the query layer using the friend list you already have client-side, then rely on RLS as defense-in-depth. At 10k users this is the difference between a feed load in 80ms and 800ms.

---

## P2 — Polish and scale

- Realtime: subscribe to `notifications` and `posts` via Supabase Realtime so the feed updates without a pull-to-refresh. Not a blocker; a meaningful UX win.
- Pagination on feed and comments (keyset on `created_at, id`).
- Telemetry: Sentry or equivalent on both client and edge function. The app currently has no way to know when something failed in production.
- Contact matching: schema added `normalized_email_hash` (migration `202604230002`) but the client never hashes the user's contact book and posts it. Either finish the feature or drop the column.
- `friendships` currently permits asymmetric rows; moving to a canonical `(least(uid, fid), greatest(uid, fid))` representation halves the row count and eliminates the "two rows / one friendship" ambiguity. Worth doing during a schema consolidation pass post-launch.
- Move the hardcoded reaction kinds (`cheers / spark / fire`) to a `reaction_kinds` table so you can add new ones without a client release.

---

## Suggested sequencing

Two weeks, one engineer focused, is a realistic estimate if you already have a linked Supabase project.

- **Week 1:** deployment state (P0 #5) → comments default (P0 #1) → profile auto-create trigger (P1) → RLS tightening on posts/comments/reactions/profiles (P0 #3) → reserved usernames to DB (P1). All schema work, low iteration cost.
- **Week 2:** friend request workflow (P0 #2) end-to-end, including UI, and APNs plumbing (P0 #4). These are the two big chunks of real work. Do them in parallel if you have a second engineer.
- **Week 3 if needed:** avatar versioning, post/comment deletion, telemetry, TestFlight hardening, and a pass through the feed query after RLS lands.

I would not ship publicly until all P0 items and the first three P1 items are in. The cost of shipping without them is not hypothetical — it's "a motivated reviewer finds the friendship-bypass issue in the first week and writes about it."

---

## What's already good (internalize this)

The architecture choices here are the kind that pay compounding returns, and I want to be specific about why so you can make more of them:

- **Protocol-first backend client with a mock implementation.** `SocialBackendClient` + `MockSocialBackendClient` means the UI can be developed and demo'd without a live backend, and it isolates networking bugs from product bugs. This is the pattern most teams skip and regret at month four.
- **Optimistic updates with server reconciliation.** `AppStore+Posting` updates UI immediately, calls the backend, and refreshes. The right tradeoff for a social app where perceived latency is the product.
- **Normalized, validated usernames.** Client-side `UsernameRules.normalized()` plus a server-side CHECK regex plus a unique constraint is belt-and-suspenders-and-zipper. Few teams do all three.
- **Triggers for notifications instead of application-layer fan-out.** The right call. Keeps the write path transactional and survives client bugs.
- **No secrets in source.** Info.plist-based config is the correct iOS pattern.

The gaps in this report are all the predictable ones for an app that shipped its happy path first. The bones are good.
