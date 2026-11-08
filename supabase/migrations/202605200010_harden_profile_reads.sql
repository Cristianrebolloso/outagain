-- Harden profile reads.
--
-- The previous username-search policy allowed any authenticated user to scan
-- every onboarded profile row. Keep direct table reads for the viewer, friends,
-- request counterparts, and admins, then move discovery to exact-match RPCs
-- that return only public profile fields.

alter table if exists public.profiles
  drop column if exists normalized_email_hash;

drop policy if exists "profiles are readable by signed-in users" on public.profiles;
drop policy if exists "profiles readable for username search" on public.profiles;
drop policy if exists "profiles readable to friends and requesters" on public.profiles;
drop policy if exists "profiles readable to friends requesters and admins" on public.profiles;

create policy "profiles readable to friends requesters and admins"
on public.profiles
for select
to authenticated
using (
  public.is_app_admin(auth.uid())
  or id = auth.uid()
  or public.is_friend(auth.uid(), id)
  or exists (
    select 1
    from public.friendships f
    where f.status in ('pending', 'blocked')
      and (
        (f.user_id = auth.uid() and f.friend_id = id)
        or (f.friend_id = auth.uid() and f.user_id = id)
      )
  )
);

revoke select on table public.profiles from anon, authenticated;

grant select (
  id,
  username,
  display_name,
  avatar_path,
  avatar_version,
  created_at,
  updated_at,
  favorite_drink,
  background_theme,
  is_verified,
  custom_drinks,
  deleted_drink_names,
  drink_order_names,
  app_announcements_started_at
) on table public.profiles to authenticated;

create or replace function public.is_username_available(search_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with candidate as (
    select lower(btrim(coalesce($1, ''))) as username
  )
  select case
    when candidate.username !~ '^[a-z0-9_]{3,20}$' then false
    else not exists (
      select 1
      from public.profiles p
      where lower(p.username) = candidate.username
        and p.id <> auth.uid()
    )
  end
  from candidate;
$$;

revoke all on function public.is_username_available(text) from public;
revoke all on function public.is_username_available(text) from anon;
grant execute on function public.is_username_available(text) to authenticated;

drop function if exists public.profiles_by_exact_usernames(text[]);
create function public.profiles_by_exact_usernames(search_usernames text[])
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
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.background_theme, 'standard') as background_theme,
    coalesce(p.is_verified, false) as is_verified
  from normalized n
  join public.profiles p
    on lower(p.username) = n.username
  where p.username is not null
    and coalesce(p.is_banned, false) = false
  order by p.display_name asc, p.username asc;
$$;

revoke all on function public.profiles_by_exact_usernames(text[]) from public;
revoke all on function public.profiles_by_exact_usernames(text[]) from anon;
grant execute on function public.profiles_by_exact_usernames(text[]) to authenticated;

drop function if exists public.profile_suggestions_for_viewer(uuid, integer);
create function public.profile_suggestions_for_viewer(viewer_id uuid, lim integer default 12)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  background_theme text,
  is_verified boolean,
  mutual_count integer
)
language sql
stable
security definer
set search_path = public
as $$
  with me as (
    select auth.uid() as id
    where auth.uid() = $1
  ),
  my_friends as (
    select case
      when f.user_id = me.id then f.friend_id
      else f.user_id
    end as friend_id
    from public.friendships f
    join me on true
    where f.status = 'accepted'
      and (f.user_id = me.id or f.friend_id = me.id)
  ),
  existing_relationships as (
    select case
      when f.user_id = me.id then f.friend_id
      else f.user_id
    end as profile_id
    from public.friendships f
    join me on true
    where f.status in ('accepted', 'pending', 'blocked', 'rejected')
      and (f.user_id = me.id or f.friend_id = me.id)
  ),
  fof_with_bridge as (
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
  ),
  ranked as (
    select
      fof_id as id,
      count(distinct bridge_friend_id)::integer as mutual_count
    from fof_with_bridge
    where fof_id <> $1
      and not exists (
        select 1
        from existing_relationships existing
        where existing.profile_id = fof_id
      )
    group by fof_id
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.background_theme, 'standard') as background_theme,
    coalesce(p.is_verified, false) as is_verified,
    ranked.mutual_count
  from ranked
  join public.profiles p on p.id = ranked.id
  where p.username is not null
    and coalesce(p.is_banned, false) = false
  order by ranked.mutual_count desc, p.display_name asc, p.username asc
  limit least(greatest(coalesce($2, 12), 1), 24);
$$;

revoke all on function public.profile_suggestions_for_viewer(uuid, integer) from public;
revoke all on function public.profile_suggestions_for_viewer(uuid, integer) from anon;
grant execute on function public.profile_suggestions_for_viewer(uuid, integer) to authenticated;

drop function if exists public.friends_for_profile(uuid);
create function public.friends_for_profile(profile_id uuid)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  background_theme text,
  is_verified boolean,
  favorite_drink text
)
language sql
stable
security definer
set search_path = public
as $$
  with visible_profile as (
    select p.id
    from public.profiles p
    where p.id = $1
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
    where f.user_id = $1
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, visible_profile
    where f.friend_id = $1
      and f.status = 'accepted'
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.background_theme, 'standard') as background_theme,
    coalesce(p.is_verified, false) as is_verified,
    p.favorite_drink
  from friend_ids
  join public.profiles p on p.id = friend_ids.id
  where p.username is not null
    and coalesce(p.is_banned, false) = false
  order by p.display_name asc, p.username asc;
$$;

revoke all on function public.friends_for_profile(uuid) from public;
revoke all on function public.friends_for_profile(uuid) from anon;
grant execute on function public.friends_for_profile(uuid) to authenticated;

create or replace function public.friend_count_for_profile(profile_id uuid)
returns table (count bigint)
language sql
stable
security definer
set search_path = public
as $$
  with visible_profile as (
    select p.id
    from public.profiles p
    where p.id = $1
      and p.username is not null
      and coalesce(p.is_banned, false) = false
      and (
        p.id = auth.uid()
        or public.is_friend(auth.uid(), p.id)
        or public.is_app_admin(auth.uid())
      )
  )
  select count(*)::bigint as count
  from (
    select f.friend_id as id
    from public.friendships f, visible_profile
    where f.user_id = $1
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f, visible_profile
    where f.friend_id = $1
      and f.status = 'accepted'
  ) friend_ids;
$$;

revoke all on function public.friend_count_for_profile(uuid) from public;
revoke all on function public.friend_count_for_profile(uuid) from anon;
grant execute on function public.friend_count_for_profile(uuid) to authenticated;

create extension if not exists pgcrypto;

alter table if exists public.banned_users
  add column if not exists email_hash text;

create or replace function public.normalized_email_sha256(raw_email text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when nullif(btrim(raw_email), '') is null then null
    else encode(extensions.digest(lower(btrim(raw_email)), 'sha256'), 'hex')
  end;
$$;

revoke all on function public.normalized_email_sha256(text) from public;
grant execute on function public.normalized_email_sha256(text) to authenticated;
grant execute on function public.normalized_email_sha256(text) to service_role;

create or replace function public.is_profile_banned(user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with target as (
    select coalesce($1, auth.uid()) as id
  ),
  allowed_target as (
    select target.id
    from target
    where target.id = auth.uid()
       or public.is_app_admin(auth.uid())
  )
  select coalesce((
    select
      coalesce((
        select p.is_banned
        from public.profiles p
        where p.id = allowed_target.id
      ), false)
      or exists (
        select 1
        from public.banned_users b
        where b.user_id = allowed_target.id
      )
      or exists (
        select 1
        from auth.users u
        join public.banned_users b
          on b.email_hash = public.normalized_email_sha256(u.email)
        where u.id = allowed_target.id
          and b.email_hash is not null
      )
    from allowed_target
  ), false);
$$;

revoke all on function public.is_profile_banned(uuid) from public;
revoke all on function public.is_profile_banned(uuid) from anon;
grant execute on function public.is_profile_banned(uuid) to authenticated;
