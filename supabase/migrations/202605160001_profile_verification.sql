-- Server-driven profile verification.
--
-- The app reads profiles.is_verified everywhere it hydrates UserProfile.
-- Once this migration is live, admins can verify or unverify accounts from
-- the backend and any app build that includes the field will update on the
-- next bootstrap/refresh without another App Store release.

alter table if exists public.profiles
  add column if not exists is_verified boolean not null default false;

-- Preserve accounts that were previously verified by the older hard-coded
-- client list. Future verification changes should come from the backend.
update public.profiles
set is_verified = true
where lower(username) in ('cristian', 'maddox', 'obama');

create or replace function public.protect_profile_verification()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), current_user) in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.is_verified = false;
    return new;
  end if;

  if new.is_verified is distinct from old.is_verified then
    raise exception 'Only app admins can change profile verification.';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_verification on public.profiles;
create trigger profiles_protect_verification
before insert or update of is_verified on public.profiles
for each row
execute procedure public.protect_profile_verification();

create or replace function public.set_profile_verified(profile_username text, verified boolean default true)
returns table (
  id uuid,
  username text,
  is_verified boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  update public.profiles p
  set is_verified = verified
  where lower(p.username) = lower(profile_username)
  returning p.id, p.username, p.is_verified;

  if not found then
    raise exception 'No profile found for username "%".', profile_username;
  end if;
end;
$$;

revoke all on function public.set_profile_verified(text, boolean) from public;
revoke all on function public.set_profile_verified(text, boolean) from anon;
revoke all on function public.set_profile_verified(text, boolean) from authenticated;
grant execute on function public.set_profile_verified(text, boolean) to service_role;

drop function if exists public.friends_for_profile(uuid);

create function public.friends_for_profile(profile_id uuid)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  is_verified boolean,
  favorite_drink text,
  apple_user_identifier text
)
language sql
stable
security definer
set search_path = public
as $$
  with friend_ids as (
    select f.friend_id as id
    from public.friendships f
    where f.user_id = profile_id
      and f.status = 'accepted'

    union

    select f.user_id as id
    from public.friendships f
    where f.friend_id = profile_id
      and f.status = 'accepted'
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    p.is_verified,
    p.favorite_drink,
    p.apple_user_identifier
  from friend_ids
  join public.profiles p on p.id = friend_ids.id
  where p.username is not null
  order by p.display_name asc;
$$;

grant execute on function public.friends_for_profile(uuid) to authenticated;
