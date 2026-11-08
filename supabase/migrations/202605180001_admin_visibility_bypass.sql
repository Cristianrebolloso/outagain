-- Give the @admin account global moderation visibility.
--
-- Friend-only privacy still applies to normal users. @admin can read every
-- post, comment, and reaction so profile grids, the home feed, detail sheets,
-- stats, and moderation actions are not constrained by friendship rows.

drop policy if exists "posts readable to author and direct friends" on public.posts;
drop policy if exists "posts readable to author and friends" on public.posts;
drop policy if exists "posts readable to author friends and admins" on public.posts;

create policy "posts readable to author friends and admins"
on public.posts
for select
to authenticated
using (
  public.is_app_admin(auth.uid())
  or author_id = auth.uid()
  or public.is_friend(auth.uid(), author_id)
);

drop policy if exists "comments readable with direct-friend parent post" on public.comments;
drop policy if exists "comments readable with parent post" on public.comments;
drop policy if exists "comments readable with admin or visible parent post" on public.comments;

create policy "comments readable with admin or visible parent post"
on public.comments
for select
to authenticated
using (
  public.is_app_admin(auth.uid())
  or exists (
    select 1
    from public.posts p
    where p.id = comments.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

drop policy if exists "reactions readable with direct-friend parent post" on public.reactions;
drop policy if exists "reactions readable with parent post" on public.reactions;
drop policy if exists "reactions readable with admin or visible parent post" on public.reactions;

create policy "reactions readable with admin or visible parent post"
on public.reactions
for select
to authenticated
using (
  public.is_app_admin(auth.uid())
  or exists (
    select 1
    from public.posts p
    where p.id = reactions.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

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
  with me as (
    select auth.uid() as id
    where auth.uid() = tonight_feed.viewer_id
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
  ),
  admin_state as (
    select public.is_app_admin(me.id) as is_admin
    from me
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
  where exists (select 1 from me)
    and (
      coalesce((select is_admin from admin_state), false)
      or exists (select 1 from author_ids a where a.id = p.author_id)
    )
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
  where p.created_at >= since
    and (
      public.is_app_admin(auth.uid())
      or exists (select 1 from author_ids a where a.id = p.author_id)
    )
  order by p.created_at desc
  limit greatest(coalesce(lim, 20), 1);
$$;

grant execute on function public.new_feed_posts(timestamptz, int) to authenticated;
