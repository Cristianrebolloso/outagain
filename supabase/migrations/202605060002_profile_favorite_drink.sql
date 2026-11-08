alter table if exists public.profiles
  add column if not exists favorite_drink text;

drop function if exists public.friends_for_profile(uuid);

create function public.friends_for_profile(profile_id uuid)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
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
    p.favorite_drink,
    p.apple_user_identifier
  from friend_ids
  join public.profiles p on p.id = friend_ids.id
  where p.username is not null
  order by p.display_name asc;
$$;

grant execute on function public.friends_for_profile(uuid) to authenticated;

drop function if exists public.match_profiles_by_email_hashes(text[]);

create function public.match_profiles_by_email_hashes(email_hashes text[])
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  favorite_drink text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    p.favorite_drink
  from public.profiles p
  where p.normalized_email_hash = any(coalesce(email_hashes, '{}'::text[]))
    and p.username is not null
  order by p.created_at desc
  limit 24;
$$;

grant execute on function public.match_profiles_by_email_hashes(text[]) to authenticated;
