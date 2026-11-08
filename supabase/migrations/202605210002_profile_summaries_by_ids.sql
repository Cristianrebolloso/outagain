-- Public-safe batch profile lookup by id.
--
-- Migration 202605200010 (harden_profile_reads) restricted SELECT on
-- public.profiles to: self, friends, pending/blocked requesters, admins.
-- The app still needs to hydrate the AVATAR + DISPLAY NAME for arbitrary
-- users it encounters in shared contexts:
--   • commenters on a post you can read via tagging
--   • reactors on a post you can read via tagging
--   • tagged users on posts where you aren't friends with the author
--   • profile lookups returned from search/suggestion RPCs
--
-- Without a bypass, those user profiles return zero rows from RLS and the
-- client drops the comment/reactor on every refresh — exactly the regression
-- users are reporting (comments and likes disappearing).
--
-- This RPC mirrors the safe-fields pattern already used by
-- `profiles_by_exact_usernames` and `profile_suggestions_for_viewer`:
-- SECURITY DEFINER + a column allowlist that matches
-- SupabaseProfileRecord.selectList on the client. No private columns
-- (email, custom drink prefs, ban flags, etc.) are exposed.

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
    limit 200
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
