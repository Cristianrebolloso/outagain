-- Public-facing post count for any profile, so non-friend viewers can see how
-- many posts a user has made without being able to read the posts themselves.
-- Mirrors the existing friend_count_for_profile pattern: SECURITY DEFINER +
-- stable, so RLS on `posts` is bypassed but the contents are never exposed —
-- only the integer count is returned.

create or replace function public.post_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::bigint as count
  from public.posts p
  where p.author_id = profile_id;
$$;

revoke all on function public.post_count_for_profile(uuid) from public;
revoke all on function public.post_count_for_profile(uuid) from anon;
grant execute on function public.post_count_for_profile(uuid) to authenticated;
