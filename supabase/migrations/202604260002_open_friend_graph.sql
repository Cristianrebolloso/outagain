-- Open the friend graph RPCs to any authenticated viewer.
--
-- The previous `visible_profile` CTE gated both `friends_for_profile` and
-- `friend_count_for_profile` behind is_friend(), which meant a non-friend
-- viewer always got zero results — defeating the purpose of the friend list
-- (discovering and adding friends). Any authenticated user can already find
-- profiles via search, so showing accepted friendships is consistent with
-- the existing public-profile model.

create or replace function public.friends_for_profile(profile_id uuid)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  apple_user_identifier text
)
language sql
stable
security definer
set search_path = public
as $$
  with friend_ids as (
    select f.friend_id as id
    from public.friendships f
    where f.user_id = profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f
    where f.friend_id = profile_id
      and f.status = 'accepted'
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    p.apple_user_identifier
  from friend_ids
  join public.profiles p on p.id = friend_ids.id
  where p.username is not null
  order by p.display_name asc;
$$;

create or replace function public.friend_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::bigint as count
  from (
    select f.friend_id as id
    from public.friendships f
    where f.user_id = profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f
    where f.friend_id = profile_id
      and f.status = 'accepted'
  ) friend_ids;
$$;

grant execute on function public.friends_for_profile(uuid) to authenticated;
grant execute on function public.friend_count_for_profile(uuid) to authenticated;
