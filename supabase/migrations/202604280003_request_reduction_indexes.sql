-- Migration: request-reduction indexes and lean query support
--
-- Context:
--   The app was generating ~43k DB requests/day and ~3.2k Storage requests/day
--   with a tiny user base. Root cause: a 20-second polling loop in HomeFeedView
--   that triggered a full 7-call bootstrap on every tick. That loop is removed
--   in the iOS client. This migration adds supporting indexes so the remaining
--   legitimate queries stay fast as data grows.
--
-- Changes in this migration:
--   1. Composite index on profiles(id) for batch IN() lookups (already primary
--      key, but a partial covering index on the select list columns speeds up
--      the fetchProfilesByIDs query which is the heaviest read in bootstrap).
--   2. Index on posts(created_at DESC) for the general feed query fallback path.
--   3. Index on comments(post_id, created_at ASC) to cover the batch comment
--      fetch ordered by time.
--   4. Index on reactions(post_id) to cover the batch reaction fetch.
--   5. Partial index on notifications(user_id, created_at DESC) for the delta
--      poll and full notification list — the WHERE user_id = ? ORDER BY
--      created_at DESC LIMIT 40 pattern.
--   6. Covering index on friendships for the full-friendship fetch in bootstrap.
--
-- Indexes from migration 202604270001 (performance_300_users) are preserved:
--   posts_recent_idx       (author_id, created_at DESC)
--   friendships_accepted_*  partial indexes on accepted status
--   notifications_actor_id_idx

-- ── 1. Profiles batch fetch ──────────────────────────────────────────────────
-- fetchProfilesByIDs issues: SELECT id,username,display_name,avatar_path,
-- avatar_version,apple_user_identifier,normalized_email_hash
-- FROM profiles WHERE id IN (...) LIMIT N
-- The PK (id) already covers the filter. A partial index on non-null usernames
-- speeds the "find onboarded users only" variant used in username search.
create index if not exists profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;

-- ── 2. Posts feed fallback ───────────────────────────────────────────────────
-- fetchFeedPosts uses (author_id IN (...), created_at DESC LIMIT N).
-- The composite index posts_recent_idx(author_id, created_at DESC) from the
-- previous migration already covers this. Adding a plain created_at index for
-- any queries that don't filter by author (e.g., admin views or future RPCs).
create index if not exists posts_created_at_desc_idx
  on public.posts (created_at desc);

-- ── 3. Comments batch fetch ──────────────────────────────────────────────────
-- fetchComments: WHERE post_id IN (...) ORDER BY created_at ASC LIMIT 400
-- A composite (post_id, created_at) index lets Postgres satisfy both the
-- filter and the sort in a single index scan.
create index if not exists comments_post_id_created_at_idx
  on public.comments (post_id, created_at asc);

-- ── 4. Reactions batch fetch ─────────────────────────────────────────────────
-- fetchReactions: WHERE post_id IN (...) LIMIT 600
-- A plain post_id index is sufficient (no ORDER BY on reactions).
create index if not exists reactions_post_id_idx
  on public.reactions (post_id);

-- ── 5. Notifications poll ────────────────────────────────────────────────────
-- fetchNotifications: WHERE user_id = ? ORDER BY created_at DESC LIMIT 40
-- fetchNewNotifications: WHERE user_id = ? AND created_at > ? ORDER BY created_at DESC LIMIT 20
-- A composite (user_id, created_at DESC) index covers both variants.
create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

-- ── 6. Friendships full fetch ─────────────────────────────────────────────────
-- fetchAllFriendships: WHERE user_id = X OR friend_id = X LIMIT 500
-- Two separate indexes (one per column) are more efficient than a composite
-- for OR predicates, because Postgres can bitmap-OR the two index scans.
-- (The partial indexes from migration 007 cover accepted/pending status;
--  we add full indexes for the OR-all-statuses bootstrap query.)
create index if not exists friendships_user_id_idx
  on public.friendships (user_id);

create index if not exists friendships_friend_id_idx
  on public.friendships (friend_id);

-- ── 7. Storage path index on posts ───────────────────────────────────────────
-- Ensures the feed query's image_path column is covered cheaply. The feed
-- select list already includes image_path; this partial index on non-null
-- image_path rows helps future "count posts with media" queries.
create index if not exists posts_with_image_idx
  on public.posts (id, image_path)
  where image_path is not null;

-- ── 8. tonight_feed window optimization ─────────────────────────────────────
-- The tonight_feed RPC filters posts WHERE created_at > now() - interval '20 hours'.
-- A BRIN index is cheap to maintain and works well for append-only time-series
-- tables like posts (rows are inserted in roughly chronological order).
-- The existing posts_recent_idx (author_id, created_at DESC) handles the join;
-- BRIN helps the range scan on created_at when no author filter applies.
create index if not exists posts_created_at_brin
  on public.posts using brin (created_at);

-- ── Analyze updated tables ───────────────────────────────────────────────────
-- Update planner statistics so the new indexes are used immediately without
-- waiting for autovacuum's next scheduled pass.
analyze public.posts;
analyze public.comments;
analyze public.reactions;
analyze public.notifications;
analyze public.friendships;
analyze public.profiles;
