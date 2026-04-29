-- Performance hardening for 300 concurrent users.
--
-- Three problems addressed:
--
-- 1. MISSING PARTIAL INDEXES on friendships.
--    is_friend() and every fan-out query hit friendships with
--    status = 'accepted'. The existing composite indexes include status as the
--    third column, which means the planner can use them for equality scans but
--    cannot use a partial index shortcut. Adding partial indexes on the two
--    lookup directions lets the planner skip all non-accepted rows at the
--    storage level rather than filtering them post-scan.
--
-- 2. FoF RLS CORRELATED SUBQUERY calling friends_of_friends_ids() per row.
--    The last migration put a set-returning function inside an EXISTS() that
--    runs for every post row evaluated during a query. We replace that with a
--    materialized fof_cache table, populated by trigger on friendship changes,
--    so the RLS check becomes a single indexed lookup.
--
-- 3. TONIGHT-WINDOW POST FILTER.
--    fetchFeedPosts currently fetches the newest 60 posts with no time window.
--    As posts accumulate this silently pulls in old content. We add a
--    tonight_feed RPC that constrains to a 20-hour window so the query stays
--    cheap regardless of total post history.
--
-- 4. NOTIFICATIONS LIGHT POLL RPC.
--    The iOS client currently re-fetches the entire bootstrap every 60s (was 20s).
--    We add a lightweight RPC that returns only new notification rows since a
--    given timestamp, so the poll cycle is a ~200-byte response instead of a
--    full bootstrap payload.
--
-- 5. PUSH_ATTEMPTS CLEANUP.
--    Unbounded growth guard: delete rows older than 14 days automatically.

-- ── 1. Partial indexes on friendships ──────────────────────────────────────

create index if not exists friendships_accepted_user_idx
  on public.friendships (user_id)
  where status = 'accepted';

create index if not exists friendships_accepted_friend_idx
  on public.friendships (friend_id)
  where status = 'accepted';

-- Index for pending request queries (friend request inbox/outbox)
create index if not exists friendships_pending_friend_idx
  on public.friendships (friend_id)
  where status = 'pending';

create index if not exists friendships_pending_user_idx
  on public.friendships (user_id)
  where status = 'pending';

-- ── 2. FoF membership cache ─────────────────────────────────────────────────

create table if not exists public.fof_cache (
  viewer_id   uuid not null references public.profiles(id) on delete cascade,
  fof_id      uuid not null references public.profiles(id) on delete cascade,
  primary key (viewer_id, fof_id)
);

create index if not exists fof_cache_viewer_idx on public.fof_cache (viewer_id);
create index if not exists fof_cache_fof_idx    on public.fof_cache (fof_id);

-- Rebuild the full FoF set for a given viewer.
-- Called from the friendship trigger and on demand.
create or replace function public.rebuild_fof_cache(p_viewer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.fof_cache where viewer_id = p_viewer_id;

  insert into public.fof_cache (viewer_id, fof_id)
  select distinct p_viewer_id, fof.fof_id
  from (
    -- my direct friends
    with my_friends as (
      select case when f.user_id = p_viewer_id then f.friend_id else f.user_id end as friend_id
      from public.friendships f
      where f.status = 'accepted'
        and (f.user_id = p_viewer_id or f.friend_id = p_viewer_id)
    )
    -- their friends
    select case when f.user_id = mf.friend_id then f.friend_id else f.user_id end as fof_id
    from public.friendships f
    join my_friends mf on (f.user_id = mf.friend_id or f.friend_id = mf.friend_id)
    where f.status = 'accepted'
  ) fof
  where fof.fof_id <> p_viewer_id
    and not exists (
      select 1 from public.friendships direct
      where direct.status = 'accepted'
        and (
          (direct.user_id = p_viewer_id and direct.friend_id = fof.fof_id)
          or
          (direct.friend_id = p_viewer_id and direct.user_id = fof.fof_id)
        )
    )
  on conflict (viewer_id, fof_id) do nothing;
end;
$$;

-- Rebuild FoF cache for both parties when a friendship changes.
create or replace function public.refresh_fof_on_friendship_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  uid_a uuid;
  uid_b uuid;
begin
  uid_a := coalesce(new.user_id,   old.user_id);
  uid_b := coalesce(new.friend_id, old.friend_id);

  -- Only act when an accepted friendship is created, removed, or status changes.
  if (TG_OP = 'INSERT' and new.status = 'accepted')
  or (TG_OP = 'DELETE' and old.status = 'accepted')
  or (TG_OP = 'UPDATE' and (old.status = 'accepted' or new.status = 'accepted'))
  then
    perform public.rebuild_fof_cache(uid_a);
    perform public.rebuild_fof_cache(uid_b);

    -- Also rebuild FoF caches for all their existing friends, since
    -- a new connection changes who appears in their friends-of-friends set.
    perform public.rebuild_fof_cache(f.friend_id)
    from public.friendships f
    where f.user_id = uid_a and f.status = 'accepted';

    perform public.rebuild_fof_cache(f.user_id)
    from public.friendships f
    where f.friend_id = uid_a and f.status = 'accepted';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists friendships_refresh_fof on public.friendships;
create trigger friendships_refresh_fof
after insert or update or delete on public.friendships
for each row execute procedure public.refresh_fof_on_friendship_change();

-- Replace the correlated-subquery RLS policy on posts with a cache lookup.
drop policy if exists "posts readable to author and friends" on public.posts;
create policy "posts readable to author and friends"
on public.posts
for select
to authenticated
using (
  author_id = auth.uid()
  or public.is_friend(auth.uid(), author_id)
  or exists (
    select 1 from public.fof_cache
    where viewer_id = auth.uid() and fof_id = posts.author_id
  )
);

-- Mirror on comments and reactions.
drop policy if exists "comments readable with parent post" on public.comments;
create policy "comments readable with parent post"
on public.comments
for select
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = comments.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
        or exists (
          select 1 from public.fof_cache
          where viewer_id = auth.uid() and fof_id = p.author_id
        )
      )
  )
);

drop policy if exists "reactions readable with parent post" on public.reactions;
create policy "reactions readable with parent post"
on public.reactions
for select
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = reactions.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
        or exists (
          select 1 from public.fof_cache
          where viewer_id = auth.uid() and fof_id = p.author_id
        )
      )
  )
);

-- fof_cache is internal — no direct client access needed.
alter table public.fof_cache enable row level security;
drop policy if exists "fof_cache service role only" on public.fof_cache;
create policy "fof_cache service role only"
on public.fof_cache for all to authenticated
using (false) with check (false);

-- ── 3. Tonight feed RPC ─────────────────────────────────────────────────────
-- Returns posts within a 20-hour window for the viewer's friend + FoF graph.
-- 20 hours covers "last night" for early risers and keeps the query anchored
-- to recent data regardless of total post history depth.

create or replace function public.tonight_feed(viewer_id uuid, lim int default 60)
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
    -- viewer's own posts
    select viewer_id as id
    union
    -- direct friends
    select case when f.user_id = viewer_id then f.friend_id else f.user_id end
    from public.friendships f
    where f.status = 'accepted'
      and (f.user_id = viewer_id or f.friend_id = viewer_id)
    union
    -- friends-of-friends via cache
    select fof_id from public.fof_cache where viewer_id = tonight_feed.viewer_id
  )
  select
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
  order by p.created_at desc
  limit lim;
$$;

grant execute on function public.tonight_feed(uuid, int) to authenticated;

-- ── 4. Light-poll notifications RPC ─────────────────────────────────────────
-- Returns only notifications newer than `since`, so the 60s poll cycle
-- transfers ~200 bytes instead of re-fetching the full notifications table.

create or replace function public.new_notifications(since timestamptz, lim int default 20)
returns table (
  id uuid, actor_id uuid, post_id uuid, comment_id uuid,
  kind text, title text, detail text, read_at timestamptz, created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select id, actor_id, post_id, comment_id, kind, title, detail, read_at, created_at
  from public.notifications
  where user_id = auth.uid()
    and created_at > since
  order by created_at desc
  limit lim;
$$;

grant execute on function public.new_notifications(timestamptz, int) to authenticated;

-- ── 5. Push attempts auto-cleanup ───────────────────────────────────────────
-- Keeps the table from growing unbounded. Runs as a trigger on insert so
-- old rows are pruned opportunistically without needing pg_cron.

create or replace function public.prune_old_push_attempts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Delete rows older than 14 days in small batches to avoid lock contention.
  delete from public.push_attempts
  where id in (
    select id from public.push_attempts
    where created_at < now() - interval '14 days'
    limit 50
  );
  return new;
end;
$$;

drop trigger if exists push_attempts_prune on public.push_attempts;
create trigger push_attempts_prune
after insert on public.push_attempts
for each statement
execute procedure public.prune_old_push_attempts();

-- ── Index on posts (author_id, created_at) for the tonight window filter ─────
-- Covers tonight_feed's join on author_id + ORDER BY created_at desc.
-- A partial index with now() in the WHERE clause is not allowed in Postgres
-- (index predicates must be IMMUTABLE). A plain composite index on the two
-- columns the query actually filters/sorts on is both legal and sufficient —
-- the planner will range-scan just the recent slice via created_at.
create index if not exists posts_recent_idx
  on public.posts (author_id, created_at desc);


-- ── Index on notifications.actor_id for the delta poll embed join ────────────
-- PostgREST resolves the notifications→profiles join via actor_id.
-- Without an index this is a seq scan on profiles for every notification row.
create index if not exists notifications_actor_id_idx
  on public.notifications (actor_id)
  where actor_id is not null;

-- ── Grant fof_cache read to the tonight_feed security definer function ───────
-- The function already runs as security definer so it bypasses RLS,
-- but the table must be grantable to the role the function executes as.
grant select on public.fof_cache to authenticated;

-- ── Seed the fof_cache for existing users ───────────────────────────────────
-- Backfill: rebuild FoF cache for every existing profile so the cache is
-- populated on first deploy rather than only after the next friendship change.
do $$
declare
  r record;
begin
  for r in select id from public.profiles loop
    perform public.rebuild_fof_cache(r.id);
  end loop;
end;
$$;
