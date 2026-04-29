-- Friends-of-friends feed support.
--
-- Two changes:
--
-- 1. `friends_of_friends_ids(viewer_id)` RPC — returns the UUIDs of users who
--    are friends-of-friends of the viewer (i.e. accepted friends of the
--    viewer's accepted friends, excluding the viewer themselves and the
--    viewer's direct friends). Used by the client bootstrap to know which
--    author_ids to fetch for the FoF feed tab, and to populate the
--    friendOfFriendIDs set in AppStore.
--
-- 2. Posts RLS — broadens the SELECT policy to allow the viewer to read posts
--    authored by a friend-of-friend. Without this, the PostgREST query for
--    FoF posts returns empty regardless of what author_ids the client sends.

-- 1. friends_of_friends_ids ------------------------------------------------

create or replace function public.friends_of_friends_ids(viewer_id uuid)
returns table (id uuid)
language sql
stable
security definer
set search_path = public
as $$
  with my_friends as (
    select case
      when f.user_id = viewer_id then f.friend_id
      else f.user_id
    end as friend_id
    from public.friendships f
    where f.status = 'accepted'
      and (f.user_id = viewer_id or f.friend_id = viewer_id)
  ),
  fof as (
    select case
      when f.user_id = mf.friend_id then f.friend_id
      else f.user_id
    end as fof_id
    from public.friendships f
    join my_friends mf
      on (f.user_id = mf.friend_id or f.friend_id = mf.friend_id)
    where f.status = 'accepted'
  )
  select distinct fof.fof_id as id
  from fof
  where fof.fof_id <> viewer_id
    and not exists (
      select 1 from my_friends mf where mf.friend_id = fof.fof_id
    );
$$;

grant execute on function public.friends_of_friends_ids(uuid) to authenticated;

-- 2. Broaden posts RLS to include friends-of-friends ----------------------

drop policy if exists "posts readable to author and friends" on public.posts;
create policy "posts readable to author and friends"
on public.posts
for select
to authenticated
using (
  author_id = auth.uid()
  or public.is_friend(auth.uid(), author_id)
  or exists (
    select 1 from public.friends_of_friends_ids(auth.uid()) fof
    where fof.id = posts.author_id
  )
);

-- Mirror the broadened policy on comments and reactions so FoF post detail
-- and reaction sheets load correctly.

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
          select 1 from public.friends_of_friends_ids(auth.uid()) fof
          where fof.id = p.author_id
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
          select 1 from public.friends_of_friends_ids(auth.uid()) fof
          where fof.id = p.author_id
        )
      )
  )
);
