-- Restore People search without requiring an app update.
--
-- The shipped client calls this RPC with the current username search fragment.
-- After profile-read hardening, the function only returned exact username
-- matches, which made search look broken until someone typed a full handle.
-- Keep the existing function name/signature for deployed clients, but allow a
-- single search fragment to return public-safe prefix matches.

create index if not exists profiles_username_lower_pattern_idx
on public.profiles ((lower(username)) text_pattern_ops);

create or replace function public.profiles_by_exact_usernames(search_usernames text[])
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
  with normalized as (
    select distinct lower(btrim(raw_username.username)) as username
    from unnest(coalesce($1, '{}'::text[])) as raw_username(username)
    where lower(btrim(raw_username.username)) ~ '^[a-z0-9_]{3,20}$'
    limit 24
  ),
  query_count as (
    select count(*) as total
    from normalized
  ),
  ranked_matches as (
    select distinct on (p.id)
      p.id,
      p.username,
      p.display_name,
      p.avatar_path,
      p.avatar_version,
      coalesce(p.background_theme, 'standard') as background_theme,
      coalesce(p.is_verified, false) as is_verified,
      case when lower(p.username) = n.username then 0 else 1 end as match_rank
    from normalized n
    cross join query_count qc
    join public.profiles p
      on lower(p.username) = n.username
      or (
        qc.total = 1
        and lower(p.username) like n.username || '%'
      )
    where p.username is not null
      and coalesce(p.is_banned, false) = false
    order by
      p.id,
      case when lower(p.username) = n.username then 0 else 1 end,
      p.display_name asc,
      p.username asc
  )
  select
    ranked_matches.id,
    ranked_matches.username,
    ranked_matches.display_name,
    ranked_matches.avatar_path,
    ranked_matches.avatar_version,
    ranked_matches.background_theme,
    ranked_matches.is_verified
  from ranked_matches
  order by match_rank asc, display_name asc, username asc
  limit 24;
$$;

revoke all on function public.profiles_by_exact_usernames(text[]) from public;
revoke all on function public.profiles_by_exact_usernames(text[]) from anon;
grant execute on function public.profiles_by_exact_usernames(text[]) to authenticated;

comment on function public.profiles_by_exact_usernames(text[])
is 'Returns public profile summaries for exact username lookups and single-query username prefix search. Name is kept for deployed client compatibility.';
