-- Dedicated friend-count surface for profile headers.
--
-- The full `friends_for_profile` RPC is still used for the sheet list, but
-- the header only needs a count. Keeping this as a tiny aggregate avoids
-- coupling the number to profile-row hydration and lets the client display
-- a truthful count even when it doesn't need the full friend graph yet.

create or replace function public.friend_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with visible_profile as (
    select profile_id
    where auth.uid() = profile_id
       or public.is_friend(auth.uid(), profile_id)
  )
  select count(*)::bigint as count
  from (
    select f.friend_id as id
    from public.friendships f, visible_profile
    where f.user_id = profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, visible_profile
    where f.friend_id = profile_id
      and f.status = 'accepted'
  ) friend_ids;
$$;

grant execute on function public.friend_count_for_profile(uuid) to authenticated;
