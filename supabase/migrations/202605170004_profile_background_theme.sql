alter table if exists public.profiles
  add column if not exists background_theme text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_background_theme_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_background_theme_check
      check (
        background_theme is null
        or background_theme in ('standard', 'night', 'orange', 'green', 'pink', 'blue')
      );
  end if;
end $$;

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
    coalesce(p.background_theme, 'standard') as background_theme,
    coalesce(p.is_verified, false) as is_verified,
    p.favorite_drink,
    p.apple_user_identifier
  from friend_ids
  join public.profiles p on p.id = friend_ids.id
  where p.username is not null
  order by p.display_name asc;
$$;

grant execute on function public.friends_for_profile(uuid) to authenticated;
