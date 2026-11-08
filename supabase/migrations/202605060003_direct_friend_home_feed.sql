-- Make the Home feed direct-friends-only and page in six-post batches.
--
-- The old home feed path still mixed friends-of-friends into the server-side
-- author set. Because the client caps each page, active FoF authors could
-- displace a direct friend's posts from the feed. The Home feed should only
-- include the viewer and accepted direct friends; FoF remains available to
-- friend suggestions through friends_of_friends_ids().

create or replace function public.tonight_feed(viewer_id uuid, lim int default 7)
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
    union
    select case
      when f.user_id = tonight_feed.viewer_id then f.friend_id
      else f.user_id
    end as id
    from public.friendships f
    where f.status = 'accepted'
      and (f.user_id = tonight_feed.viewer_id or f.friend_id = tonight_feed.viewer_id)
  )
  select
    p.id,
    p.author_id,
    p.drink_name,
    p.drink_subtitle,
    p.drink_symbol,
    p.drink_primary_hex,
    p.drink_secondary_hex,
    p.venue_name,
    p.venue_neighborhood,
    p.venue_city,
    p.venue_latitude,
    p.venue_longitude,
    p.latitude,
    p.longitude,
    p.horizontal_accuracy,
    p.caption,
    p.image_path,
    p.tagged_user_ids,
    p.is_shared_moment,
    p.created_at
  from public.posts p
  join author_ids a on a.id = p.author_id
  order by p.created_at desc
  limit greatest(coalesce(lim, 7), 1);
$$;

grant execute on function public.tonight_feed(uuid, int) to authenticated;

create or replace function public.new_feed_posts(since timestamptz, lim int default 20)
returns table (
  id uuid,
  author_id uuid,
  drink_name text,
  drink_subtitle text,
  drink_symbol text,
  drink_primary_hex text,
  drink_secondary_hex text,
  venue_name text,
  venue_neighborhood text,
  venue_city text,
  venue_latitude double precision,
  venue_longitude double precision,
  latitude double precision,
  longitude double precision,
  horizontal_accuracy double precision,
  caption text,
  image_path text,
  tagged_user_ids uuid[],
  is_shared_moment boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as id
  ),
  author_ids as (
    select id from me
    union
    select case
      when f.user_id = me.id then f.friend_id
      else f.user_id
    end as id
    from public.friendships f
    join me on true
    where f.status = 'accepted'
      and (f.user_id = me.id or f.friend_id = me.id)
  )
  select
    p.id,
    p.author_id,
    p.drink_name,
    p.drink_subtitle,
    p.drink_symbol,
    p.drink_primary_hex,
    p.drink_secondary_hex,
    p.venue_name,
    p.venue_neighborhood,
    p.venue_city,
    p.venue_latitude,
    p.venue_longitude,
    p.latitude,
    p.longitude,
    p.horizontal_accuracy,
    p.caption,
    p.image_path,
    p.tagged_user_ids,
    p.is_shared_moment,
    p.created_at
  from public.posts p
  join author_ids a on a.id = p.author_id
  where p.created_at >= since
  order by p.created_at desc
  limit greatest(coalesce(lim, 20), 1);
$$;

grant execute on function public.new_feed_posts(timestamptz, int) to authenticated;
