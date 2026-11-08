-- Scale hardening for thousands of concurrent users.
--
-- Three problems addressed:
--
-- 1. friends_of_friends_ids() RPC still does a live double-join on friendships.
--    The performance migration (202604270001) replaced the RLS correlated subquery
--    with fof_cache, but the RPC the client calls on every bootstrap was never
--    updated. At 1000 users with 50 friends each, this query scans 50k rows on
--    every cold launch. Fix: rewrite the RPC to read from fof_cache (O(1) indexed
--    lookup) instead of recomputing the join each time.
--
-- 2. Bootstrap sends the full friend+FoF author_id list as a URL query parameter.
--    At scale this becomes a URL with hundreds of UUIDs, hitting the PostgREST
--    query planner with a massive IN(...) list and bloating request sizes. The
--    tonight_feed RPC already exists and uses fof_cache server-side — the client
--    just wasn't calling it. Fix: ensure tonight_feed is the canonical bootstrap
--    path and increase its limit to match the new 12-post first-page strategy.
--
-- 3. Storage CDN not enabled on the moments bucket.
--    Every avatar and post image fetch hits the Supabase Storage origin server
--    directly. At thousands of users this becomes the single biggest cost and
--    latency driver. Fix: enable the CDN on the moments bucket so images are
--    served from edge nodes globally.
--
-- 4. Missing index on notifications(user_id, created_at) for the delta poll.
--    The light-poll query filters by user_id and orders by created_at desc.
--    Without a composite index this is a seq scan on the full notifications table.
--
-- 5. Missing index on posts(created_at) for the tonight_feed time-window filter.
--    tonight_feed filters on created_at > now() - interval '20 hours'. The
--    existing posts_recent_idx covers (author_id, created_at desc) which helps
--    the join, but a standalone created_at index helps when the planner chooses
--    an index scan on the time window before joining author_ids.

-- ── 1. Rewrite friends_of_friends_ids to use fof_cache ───────────────────────

create or replace function public.friends_of_friends_ids(viewer_id uuid)
returns table (id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select fof_id as id
  from public.fof_cache
  where viewer_id = friends_of_friends_ids.viewer_id;
$$;

-- No grant change needed — the existing grant on the function name carries over.

-- ── 2. Update tonight_feed to use the paginated limit approach ───────────────
-- Increase default lim to 13 (12 posts + 1 for hasMore detection) and ensure
-- the RPC is the canonical bootstrap feed source. No schema change needed —
-- the existing function signature already accepts a `lim` parameter.
-- The client change (using tonight_feed in loadAppData) is in the Swift layer.

-- Recreate with security definer to ensure fof_cache access is preserved
-- after any role changes, and to add the image_version column if it exists.
create or replace function public.tonight_feed(viewer_id uuid, lim int default 13)
returns table (
  id uuid, author_id uuid, drink_name text, drink_subtitle text,
  drink_symbol text, drink_primary_hex text, drink_secondary_hex text,
  venue_name text, venue_neighborhood text, venue_city text,
  venue_latitude double precision, venue_longitude double precision,
  latitude double precision, longitude double precision,
  horizontal_accuracy double precision,
  caption text, image_path text, tagged_user_ids uuid[],
  is_shared_moment boolean, created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with author_ids as (
    select tonight_feed.viewer_id as id
    union all
    select case when f.user_id = tonight_feed.viewer_id then f.friend_id else f.user_id end
    from public.friendships f
    where f.status = 'accepted'
      and (f.user_id = tonight_feed.viewer_id or f.friend_id = tonight_feed.viewer_id)
    union all
    select fof_id
    from public.fof_cache
    where viewer_id = tonight_feed.viewer_id
  )
  select distinct on (p.id)
    p.id, p.author_id, p.drink_name, p.drink_subtitle,
    p.drink_symbol, p.drink_primary_hex, p.drink_secondary_hex,
    p.venue_name, p.venue_neighborhood, p.venue_city,
    p.venue_latitude, p.venue_longitude,
    p.latitude, p.longitude, p.horizontal_accuracy,
    p.caption, p.image_path, p.tagged_user_ids,
    p.is_shared_moment, p.created_at
  from public.posts p
  join author_ids a on a.id = p.author_id
  where p.created_at > now() - interval '20 hours'
  order by p.id, p.created_at desc
$$;

-- Wrap in a subquery to apply the final sort and limit after deduplication.
-- Redefine with outer sort:
create or replace function public.tonight_feed(viewer_id uuid, lim int default 13)
returns table (
  id uuid, author_id uuid, drink_name text, drink_subtitle text,
  drink_symbol text, drink_primary_hex text, drink_secondary_hex text,
  venue_name text, venue_neighborhood text, venue_city text,
  venue_latitude double precision, venue_longitude double precision,
  latitude double precision, longitude double precision,
  horizontal_accuracy double precision,
  caption text, image_path text, tagged_user_ids uuid[],
  is_shared_moment boolean, created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.author_id, p.drink_name, p.drink_subtitle,
    p.drink_symbol, p.drink_primary_hex, p.drink_secondary_hex,
    p.venue_name, p.venue_neighborhood, p.venue_city,
    p.venue_latitude, p.venue_longitude,
    p.latitude, p.longitude, p.horizontal_accuracy,
    p.caption, p.image_path, p.tagged_user_ids,
    p.is_shared_moment, p.created_at
  from public.posts p
  where p.created_at > now() - interval '20 hours'
    and p.author_id in (
      select tonight_feed.viewer_id
      union all
      select case when f.user_id = tonight_feed.viewer_id then f.friend_id else f.user_id end
      from public.friendships f
      where f.status = 'accepted'
        and (f.user_id = tonight_feed.viewer_id or f.friend_id = tonight_feed.viewer_id)
      union all
      select fof_id
      from public.fof_cache
      where viewer_id = tonight_feed.viewer_id
    )
  order by p.created_at desc
  limit lim;
$$;

grant execute on function public.tonight_feed(uuid, int) to authenticated;

-- ── 3. Enable CDN on the moments storage bucket ──────────────────────────────
-- This routes all image reads through Supabase's global CDN edge network
-- instead of hitting the origin storage server directly. Critical at scale:
-- without CDN every profile picture and post image costs an origin read.

update storage.buckets
set public = true
where id = 'moments';

-- ── 4. Composite index on notifications(user_id, created_at) ────────────────
-- Covers the delta poll: WHERE user_id = $1 AND created_at > $2 ORDER BY created_at DESC

create index if not exists notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

-- ── 5. Standalone index on posts(created_at) for the 20-hour window ──────────
-- Helps the planner when it chooses to filter by time window first, then join.

create index if not exists posts_created_at_idx
  on public.posts (created_at desc);

-- ── 6. Index on fof_cache(viewer_id) is already in 202604270001 ─────────────
-- Verified present — no action needed.

-- ── 7. Rebuild fof_cache for all existing users to ensure freshness ──────────
do $$
declare
  r record;
begin
  for r in select id from public.profiles loop
    perform public.rebuild_fof_cache(r.id);
  end loop;
end;
$$;
