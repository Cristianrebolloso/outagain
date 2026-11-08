-- Public identity only; matching must not grant access to private profiles.
create or replace function public.search_profiles(search_query text, result_limit integer default 24)
returns table (id uuid, username text, display_name text, avatar_path text,
  avatar_version integer, background_theme text, is_verified boolean)
language sql stable security definer set search_path = ''
as $$
  with query as (
    select lower(left(btrim(regexp_replace(coalesce($1, ''), '^\s*@', '')), 64)) as term,
      (select auth.uid()) as viewer
  )
  select p.id, p.username, p.display_name, p.avatar_path, p.avatar_version,
    coalesce(p.background_theme, 'standard'), coalesce(p.is_verified, false)
  from public.profiles p cross join query q
  where q.viewer is not null and length(q.term) >= 2
    and p.id <> q.viewer and p.username is not null
    and not coalesce(p.is_banned, false)
    and not exists (select 1 from public.profiles v where v.id=q.viewer and v.is_banned)
    and (starts_with(lower(p.username), q.term)
      or strpos(lower(coalesce(p.display_name, '')), q.term) > 0)
    and not exists (select 1 from public.friendships f where f.status='blocked'
      and ((f.user_id=q.viewer and f.friend_id=p.id)
        or (f.friend_id=q.viewer and f.user_id=p.id)))
  order by case when lower(p.username)=q.term then 0
    when lower(p.display_name)=q.term then 1
    when starts_with(lower(p.username), q.term) then 2 else 3 end,
    lower(p.display_name), lower(p.username), p.id
  limit greatest(1, least(coalesce($2,24),24));
$$;
revoke all on function public.search_profiles(text,integer) from public, anon;
grant execute on function public.search_profiles(text,integer) to authenticated;

-- Keep older clients' single-fragment username search working. Underscores
-- are literal handle characters, never LIKE wildcards. Batch lookups stay exact.
create or replace function public.profiles_by_exact_usernames(search_usernames text[])
returns table (id uuid, username text, display_name text, avatar_path text,
  avatar_version integer, background_theme text, is_verified boolean)
language sql stable security definer set search_path = ''
as $$
  with normalized as (
    select distinct lower(btrim(u)) as term
    from unnest(coalesce($1,'{}'::text[])) u
    where lower(btrim(u)) ~ '^[a-z0-9_]{2,20}$' limit 24
  ), viewer as (select (select auth.uid()) as id)
  select p.id,p.username,p.display_name,p.avatar_path,p.avatar_version,
    coalesce(p.background_theme,'standard'),coalesce(p.is_verified,false)
  from public.profiles p cross join viewer v
  where v.id is not null and not coalesce(p.is_banned,false)
    and not exists (select 1 from public.profiles me where me.id=v.id and me.is_banned)
    and exists (select 1 from normalized n where lower(p.username)=n.term
      or ((select count(*) from normalized)=1 and starts_with(lower(p.username),n.term)))
    and not exists (select 1 from public.friendships f where f.status='blocked'
      and ((f.user_id=v.id and f.friend_id=p.id) or (f.friend_id=v.id and f.user_id=p.id)))
  order by case when exists (select 1 from normalized n where lower(p.username)=n.term) then 0 else 1 end,
    lower(p.display_name),lower(p.username),p.id
  limit 24;
$$;
revoke all on function public.profiles_by_exact_usernames(text[]) from public, anon;
grant execute on function public.profiles_by_exact_usernames(text[]) to authenticated;

-- Enforce the same consent rules for direct API calls as for the iOS buttons.
create or replace function private.validate_friendship_transition()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare viewer uuid := auth.uid();
begin
  if coalesce(current_setting('role',true),'none') not in ('authenticated','anon') then
    return new;
  end if;
  if viewer is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  if new.user_id=new.friend_id then
    raise exception 'You cannot add yourself.' using errcode='23514';
  end if;
  if tg_op='UPDATE' and (new.user_id<>old.user_id or new.friend_id<>old.friend_id or new.id<>old.id) then
    raise exception 'Friendship participants cannot change.' using errcode='42501';
  end if;
  if new.status<>'blocked' and exists (select 1 from public.friendships f
    where f.status='blocked' and ((f.user_id=new.user_id and f.friend_id=new.friend_id)
      or (f.friend_id=new.user_id and f.user_id=new.friend_id))) then
    raise exception 'This friendship is unavailable.' using errcode='42501';
  end if;
  if tg_op='INSERT' and (new.user_id<>viewer or new.status not in ('pending','blocked')) then
    raise exception 'Send a request before becoming friends.' using errcode='42501';
  end if;
  if tg_op='UPDATE' then
    if old.status='blocked' and new.status<>old.status then
      raise exception 'Remove your block before sending a request.' using errcode='42501';
    end if;
    if new.status='accepted' and old.status<>'accepted'
      and (old.status<>'pending' or viewer<>old.friend_id) then
      raise exception 'Only the recipient can accept a friend request.' using errcode='42501';
    end if;
    -- A retry from a stale client must not undo an accepted friendship.
    if old.status='accepted' and new.status='pending' then return old; end if;
  end if;
  if new.status='blocked' and new.user_id<>viewer then
    raise exception 'A block must belong to its creator.' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_friendship_transition() from public,anon,authenticated;
create trigger friendships_validate_transition before insert or update on public.friendships
for each row execute function private.validate_friendship_transition();

drop policy if exists "participants can delete friendship" on public.friendships;
create policy "participants can delete friendship" on public.friendships for delete to authenticated
using (user_id=(select auth.uid()) or (friend_id=(select auth.uid()) and status<>'blocked'));
