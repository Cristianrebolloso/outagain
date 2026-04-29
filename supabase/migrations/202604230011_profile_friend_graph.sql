-- Friend graph read surface.
--
-- `friendships` stays participant-readable only under RLS, but profile
-- pages need a bounded way to show a friend's friend count and list. This
-- RPC returns accepted friends for a profile only when the caller is that
-- profile or is already friends with that profile.

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
  with visible_profile as (
    select profile_id
    where auth.uid() = profile_id
       or public.is_friend(auth.uid(), profile_id)
  ),
  friend_ids as (
    select f.friend_id as id
    from public.friendships f, visible_profile
    where f.user_id = profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, visible_profile
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

grant execute on function public.friends_for_profile(uuid) to authenticated;
