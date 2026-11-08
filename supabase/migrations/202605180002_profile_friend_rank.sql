-- Server-side friend rank for profile stats.
--
-- Friend profile screens need to rank the viewed person against that person's
-- accepted friends, not against the signed-in viewer's own friend list. Keeping
-- this as a SECURITY DEFINER aggregate avoids exposing each friend's post
-- history while still returning the exact rank and comparison group size.

drop function if exists public.profile_friend_rank(uuid);
drop function if exists public.profile_friend_rank(uuid, text);

create function public.profile_friend_rank(profile_id uuid, timezone_name text default 'UTC')
returns table (
  rank integer,
  group_size integer
)
language sql
stable
security definer
set search_path = public
as $$
  with visible_profile as (
    select p.id
    from public.profiles p
    where p.id = profile_friend_rank.profile_id
      and p.username is not null
      and coalesce(p.is_banned, false) = false
      and (
        p.id = auth.uid()
        or public.is_friend(auth.uid(), p.id)
        or public.is_app_admin(auth.uid())
      )
  ),
  friend_ids as (
    select f.friend_id as id
    from public.friendships f, visible_profile
    where f.user_id = profile_friend_rank.profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, visible_profile
    where f.friend_id = profile_friend_rank.profile_id
      and f.status = 'accepted'
  ),
  group_member_ids as (
    select id from visible_profile
    union
    select id from friend_ids
  ),
  member_night_counts as (
    select
      group_member_ids.id,
      count(distinct (
        timezone(
          coalesce(nullif(profile_friend_rank.timezone_name, ''), 'UTC'),
          posts.created_at
        ) - interval '7 hours'
      )::date)::integer as nights_out
    from group_member_ids
    left join public.posts
      on posts.author_id = group_member_ids.id
    group by group_member_ids.id
  ),
  target_count as (
    select nights_out
    from member_night_counts
    where id = profile_friend_rank.profile_id
  )
  select
    ranked.rank,
    ranked.group_size
  from target_count target
  cross join lateral (
    select
      (count(*) filter (where member.nights_out > target.nights_out) + 1)::integer as rank,
      count(*)::integer as group_size
    from member_night_counts member
  ) ranked;
$$;

revoke all on function public.profile_friend_rank(uuid, text) from public;
revoke all on function public.profile_friend_rank(uuid, text) from anon;
grant execute on function public.profile_friend_rank(uuid, text) to authenticated;
