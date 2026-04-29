-- Cheap read RPCs for a social feed:
--   1. exact engagement counts without loading every comment/reaction row
--   2. lightweight "new posts since cursor" polling for the foreground feed

create or replace function public.post_engagement_counts(post_ids uuid[])
returns table (
  post_id uuid,
  comment_count integer,
  cheers_count integer,
  spark_count integer,
  fire_count integer,
  viewer_reaction_kinds text[]
)
language sql
stable
set search_path = public
as $$
  with target_posts as (
    select distinct unnest(coalesce(post_ids, '{}'::uuid[])) as post_id
  ),
  visible_posts as (
    select p.id as post_id
    from public.posts p
    join target_posts t on t.post_id = p.id
  ),
  comment_counts as (
    select c.post_id, count(*)::integer as comment_count
    from public.comments c
    join visible_posts vp on vp.post_id = c.post_id
    group by c.post_id
  ),
  reaction_counts as (
    select
      r.post_id,
      count(*) filter (where r.kind = 'cheers')::integer as cheers_count,
      count(*) filter (where r.kind = 'spark')::integer as spark_count,
      count(*) filter (where r.kind = 'fire')::integer as fire_count,
      coalesce(
        array_agg(distinct r.kind) filter (where r.user_id = auth.uid()),
        '{}'::text[]
      ) as viewer_reaction_kinds
    from public.reactions r
    join visible_posts vp on vp.post_id = r.post_id
    group by r.post_id
  )
  select
    vp.post_id,
    coalesce(cc.comment_count, 0) as comment_count,
    coalesce(rc.cheers_count, 0) as cheers_count,
    coalesce(rc.spark_count, 0) as spark_count,
    coalesce(rc.fire_count, 0) as fire_count,
    coalesce(rc.viewer_reaction_kinds, '{}'::text[]) as viewer_reaction_kinds
  from visible_posts vp
  left join comment_counts cc on cc.post_id = vp.post_id
  left join reaction_counts rc on rc.post_id = vp.post_id;
$$;

grant execute on function public.post_engagement_counts(uuid[]) to authenticated;

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
    select case when f.user_id = me.id then f.friend_id else f.user_id end
    from public.friendships f
    join me on true
    where f.status = 'accepted'
      and (f.user_id = me.id or f.friend_id = me.id)
    union
    select fc.fof_id
    from public.fof_cache fc
    join me on fc.viewer_id = me.id
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
    and p.created_at > now() - interval '20 hours'
  order by p.created_at desc
  limit greatest(coalesce(lim, 20), 1);
$$;

grant execute on function public.new_feed_posts(timestamptz, int) to authenticated;
