-- Friend-only profile privacy.
--
-- Public profile discovery still needs basic profile rows so people can find
-- and add each other, but drinking posts are private social content. Only the
-- author and accepted direct friends should be able to read authored posts,
-- tagged-profile grids, comments/reactions on those posts, and stats computed
-- from those rows.

-- Posts: readable only by the author or accepted direct friends.
drop policy if exists "posts are readable by signed-in users" on public.posts;
drop policy if exists "posts readable to any authenticated user" on public.posts;
drop policy if exists "posts readable to author and friends" on public.posts;
drop policy if exists "posts readable to author and direct friends" on public.posts;

create policy "posts readable to author and direct friends"
on public.posts
for select
to authenticated
using (
  author_id = auth.uid()
  or public.is_friend(auth.uid(), author_id)
);

-- Comments: readable only when the parent post is readable by the same
-- direct-friend rule.
drop policy if exists "comments are readable by signed-in users" on public.comments;
drop policy if exists "comments readable to any authenticated user" on public.comments;
drop policy if exists "comments readable with parent post" on public.comments;
drop policy if exists "comments readable with direct-friend parent post" on public.comments;

create policy "comments readable with direct-friend parent post"
on public.comments
for select
to authenticated
using (
  exists (
    select 1
    from public.posts p
    where p.id = comments.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

-- Reactions: same parent-post privacy as comments.
drop policy if exists "reactions are readable by signed-in users" on public.reactions;
drop policy if exists "reactions readable to any authenticated user" on public.reactions;
drop policy if exists "reactions readable with parent post" on public.reactions;
drop policy if exists "reactions readable with direct-friend parent post" on public.reactions;

create policy "reactions readable with direct-friend parent post"
on public.reactions
for select
to authenticated
using (
  exists (
    select 1
    from public.posts p
    where p.id = reactions.post_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

-- Friend-of-friend suggestions are still allowed, but only for the signed-in
-- viewer. The previous security-definer function accepted an arbitrary
-- viewer_id parameter, which made another person's graph queryable.
create or replace function public.friends_of_friends_ids(viewer_id uuid)
returns table (id uuid, mutual_count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with my_friends as (
    select case
      when f.user_id = friends_of_friends_ids.viewer_id then f.friend_id
      else f.user_id
    end as friend_id
    from public.friendships f
    where friends_of_friends_ids.viewer_id = auth.uid()
      and f.status = 'accepted'
      and (
        f.user_id = friends_of_friends_ids.viewer_id
        or f.friend_id = friends_of_friends_ids.viewer_id
      )
  ),
  fof_with_bridge as (
    select distinct
      case
        when f.user_id = mf.friend_id then f.friend_id
        else f.user_id
      end as fof_id,
      mf.friend_id as bridge_friend_id
    from public.friendships f
    join my_friends mf
      on (f.user_id = mf.friend_id or f.friend_id = mf.friend_id)
    where f.status = 'accepted'
  )
  select
    fof_id as id,
    count(distinct bridge_friend_id) as mutual_count
  from fof_with_bridge
  where fof_id <> friends_of_friends_ids.viewer_id
    and not exists (
      select 1 from my_friends mf where mf.friend_id = fof_id
    )
  group by fof_id;
$$;

grant execute on function public.friends_of_friends_ids(uuid) to authenticated;

-- The Home feed RPC is security-definer because it needs to read efficiently
-- through friendships, so it must bind its viewer_id argument to auth.uid().
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
