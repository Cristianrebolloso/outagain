-- Public profile header counts.
--
-- Profile content stays friends-only, but the profile header should show
-- accurate aggregate counts to any signed-in viewer. These SECURITY DEFINER
-- functions return only integers, not the underlying friend graph or posts.

create or replace function public.friend_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with target_profile as (
    select p.id
    from public.profiles p
    where p.id = $1
      and p.username is not null
      and (
        coalesce(p.is_banned, false) = false
        or public.is_app_admin(auth.uid())
      )
  )
  select count(*)::bigint as count
  from (
    select f.friend_id as id
    from public.friendships f, target_profile
    where f.user_id = $1
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, target_profile
    where f.friend_id = $1
      and f.status = 'accepted'
  ) friend_ids;
$$;

revoke all on function public.friend_count_for_profile(uuid) from public;
revoke all on function public.friend_count_for_profile(uuid) from anon;
grant execute on function public.friend_count_for_profile(uuid) to authenticated;

create or replace function public.post_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with target_profile as (
    select p.id
    from public.profiles p
    where p.id = $1
      and p.username is not null
      and (
        coalesce(p.is_banned, false) = false
        or public.is_app_admin(auth.uid())
      )
  )
  select count(*)::bigint as count
  from public.posts p
  join target_profile on target_profile.id = p.author_id;
$$;

revoke all on function public.post_count_for_profile(uuid) from public;
revoke all on function public.post_count_for_profile(uuid) from anon;
grant execute on function public.post_count_for_profile(uuid) to authenticated;
