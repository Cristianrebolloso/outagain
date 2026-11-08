-- profile_summaries_by_ids capped its input at LIMIT 200 (no ORDER BY), which
-- silently dropped arbitrary IDs from the bootstrap's profileMap. Every call
-- site that compacts against profileMap then loses entries — friends list
-- collapses, post authors fall back to "Unknown", commenters disappear,
-- reactors are pruned. Raise the cap well above any realistic bootstrap fan-out
-- (friends + blocked + suggestions + post authors + tagged + commenters +
-- reactors + notification actors + pending counterparts).

drop function if exists public.profile_summaries_by_ids(uuid[]);
create function public.profile_summaries_by_ids(profile_ids uuid[])
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  background_theme text,
  is_verified boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with distinct_ids as (
    select distinct candidate
    from unnest(coalesce($1, '{}'::uuid[])) as candidate
    where candidate is not null
    limit 5000
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.background_theme, 'standard') as background_theme,
    coalesce(p.is_verified, false) as is_verified
  from distinct_ids d
  join public.profiles p on p.id = d.candidate
  where p.username is not null
    and (
      coalesce(p.is_banned, false) = false
      or public.is_app_admin(auth.uid())
    );
$$;

revoke all on function public.profile_summaries_by_ids(uuid[]) from public;
revoke all on function public.profile_summaries_by_ids(uuid[]) from anon;
grant execute on function public.profile_summaries_by_ids(uuid[]) to authenticated;
