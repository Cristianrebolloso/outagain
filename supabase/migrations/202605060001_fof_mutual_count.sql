-- Extend friends_of_friends_ids to include the mutual friend count.
--
-- The old function returned table(id uuid). The new version returns
-- table(id uuid, mutual_count bigint) — the number of the viewer's accepted
-- friends who are also accepted friends with each FoF candidate.
--
-- The client uses mutual_count to display "1 mutual", "2 mutuals", etc. in
-- the suggested friends section of the Add Friends screen.
--
-- Because the return shape changes, Postgres requires the existing function
-- to be dropped before recreating it. The grant is re-applied so the RLS
-- executor retains access.

drop function if exists public.friends_of_friends_ids(uuid);

create function public.friends_of_friends_ids(viewer_id uuid)
returns table (id uuid, mutual_count bigint)
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
  fof_with_bridge as (
    -- For each (fof_candidate, bridging_friend) pair:
    -- bridging_friend is one of the viewer's friends who is also friends with fof_candidate.
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
  where fof_id <> viewer_id
    and not exists (
      select 1 from my_friends mf where mf.friend_id = fof_id
    )
  group by fof_id;
$$;

grant execute on function public.friends_of_friends_ids(uuid) to authenticated;
