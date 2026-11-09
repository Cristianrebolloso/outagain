-- Qualify the outer profile id. The old predicate bound bare id to friendships.id,
-- hiding pending-request profiles in the direct-table/older-client path.
drop policy if exists "profiles readable to friends requesters and admins" on public.profiles;
create policy "profiles readable to friends requesters and admins"
on public.profiles for select to authenticated using (
  public.is_app_admin(auth.uid()) or profiles.id = auth.uid()
  or public.is_friend(auth.uid(), profiles.id)
  or exists (select 1 from public.friendships f
    where f.status in ('pending', 'blocked') and
      ((f.user_id = auth.uid() and f.friend_id = profiles.id)
       or (f.friend_id = auth.uid() and f.user_id = profiles.id)))
);

-- Treat keyboard/pasted whitespace consistently, including repeated spaces in names.
create or replace function public.search_profiles(search_query text, result_limit integer default 24)
returns table (id uuid, username text, display_name text, avatar_path text,
  avatar_version integer, background_theme text, is_verified boolean)
language sql stable security definer set search_path = '' as $$
  with query as (
    select lower(left(btrim(regexp_replace(regexp_replace(coalesce($1, ''),
      '^[[:space:]]*@', ''), '[[:space:]]+', ' ', 'g')), 64)) as term,
      (select auth.uid()) as viewer
  )
  select p.id, p.username, p.display_name, p.avatar_path, p.avatar_version,
    coalesce(p.background_theme, 'standard'), coalesce(p.is_verified, false)
  from public.profiles p cross join query q
  where q.viewer is not null and length(q.term) >= 2
    and p.id <> q.viewer and p.username is not null
    and not public.is_profile_banned(p.id) and not public.is_profile_banned(q.viewer)
    and (starts_with(lower(p.username), q.term)
      or strpos(lower(regexp_replace(coalesce(p.display_name, ''), '[[:space:]]+', ' ', 'g')), q.term) > 0)
    and private.users_can_interact(q.viewer, p.id)
  order by case when lower(p.username)=q.term then 0
    when lower(p.display_name)=q.term then 1
    when starts_with(lower(p.username), q.term) then 2 else 3 end,
    lower(p.display_name), lower(p.username), p.id
  limit greatest(1, least(coalesce($2,24),24));
$$;
revoke all on function public.search_profiles(text,integer) from public, anon;
grant execute on function public.search_profiles(text,integer) to authenticated;

-- One pair lock makes simultaneous reciprocal taps/retries deterministic.
create or replace function private.send_friend_request(target_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare viewer uuid := auth.uid(); existing public.friendships;
begin
  if viewer is null or target_id is null or viewer = target_id
    or not exists(select 1 from public.profiles p where p.id=viewer and p.username is not null)
    or not exists(select 1 from public.profiles p where p.id=target_id and p.username is not null)
    or not private.users_can_interact(viewer,target_id) then
    raise exception 'This friendship is unavailable.' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(least(viewer::text,target_id::text)||greatest(viewer::text,target_id::text),0));
  select * into existing from public.friendships f
    where (f.user_id=viewer and f.friend_id=target_id) or (f.user_id=target_id and f.friend_id=viewer)
    order by case f.status when 'accepted' then 0 when 'blocked' then 1 else 2 end limit 1 for update;
  if existing.status='blocked' then
    raise exception 'This friendship is unavailable.' using errcode='42501';
  elsif existing.status='accepted' then return 'accepted';
  elsif existing.status='pending' and existing.friend_id=viewer then
    update public.friendships set status='accepted' where id=existing.id;
    return 'accepted';
  elsif existing.status='pending' then return 'pending';
  end if;
  insert into public.friendships(user_id,friend_id,status) values(viewer,target_id,'pending')
    on conflict(user_id,friend_id) do update set status='pending';
  return 'pending';
end;
$$;
revoke all on function private.send_friend_request(uuid) from public,anon;
grant execute on function private.send_friend_request(uuid) to authenticated;
create or replace function public.send_friend_request(target_id uuid)
returns text language sql security invoker set search_path = '' as $$ select private.send_friend_request($1); $$;
revoke all on function public.send_friend_request(uuid) from public,anon;
grant execute on function public.send_friend_request(uuid) to authenticated;

-- Bearer codes are unguessable and never enumerable through the Data API.
create table private.social_invites (
  token text primary key check(token ~ '^[0-9a-f]{32}$'),
  inviter_id uuid not null references public.profiles(id) on delete cascade,
  group_id uuid references public.night_groups(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
alter table private.social_invites enable row level security;
revoke all on private.social_invites from public,anon,authenticated;
create index social_invites_owner_idx on private.social_invites(inviter_id,group_id);

create or replace function private.resolve_social_invite(invite_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare invite private.social_invites; inviter public.profiles; group_name text;
begin
  if auth.uid() is null or public.is_profile_banned(auth.uid()) then
    raise exception 'Sign in to open this invite.' using errcode='42501';
  end if;
  select * into invite from private.social_invites i where i.token=lower(btrim(invite_token))
    and i.expires_at>now() and i.revoked_at is null;
  if not found or not private.users_can_interact(auth.uid(),invite.inviter_id) then
    raise exception 'This invite has expired or is no longer available.' using errcode='22023';
  end if;
  select * into inviter from public.profiles p where p.id=invite.inviter_id;
  if invite.group_id is not null then
    select g.name into group_name from public.night_groups g
      where g.id=invite.group_id and invite.inviter_id=any(g.member_ids);
    if not found then raise exception 'This group invite is no longer available.' using errcode='22023'; end if;
  end if;
  return jsonb_build_object('token',invite.token,'inviter_id',inviter.id,
    'inviter_name',inviter.display_name,'inviter_username',inviter.username,
    'group_id',invite.group_id,'group_name',group_name,'expires_at',invite.expires_at);
end;
$$;
revoke all on function private.resolve_social_invite(text) from public,anon;
grant execute on function private.resolve_social_invite(text) to authenticated;
create or replace function public.resolve_social_invite(invite_token text)
returns jsonb language sql stable security invoker set search_path = '' as $$ select private.resolve_social_invite($1); $$;
revoke all on function public.resolve_social_invite(text) from public,anon;
grant execute on function public.resolve_social_invite(text) to authenticated;

create or replace function private.create_social_invite(requested_group_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare viewer uuid := auth.uid(); code text; expiry timestamptz; group_created timestamptz;
begin
  if viewer is null or public.is_profile_banned(viewer)
    or not exists(select 1 from public.profiles p where p.id=viewer and p.username is not null) then
    raise exception 'Finish setting up your profile to share an invite.' using errcode='42501';
  end if;
  expiry := now()+interval '30 days';
  if requested_group_id is not null then
    select g.created_at into group_created from public.night_groups g
      where g.id=requested_group_id and g.creator_id=viewer;
    if not found then raise exception 'Only the group creator can share its invite.' using errcode='42501'; end if;
    expiry := group_created+interval '36 hours';
    if expiry<=now() then raise exception 'Start a new group for tonight.' using errcode='22023'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(viewer::text||coalesce(requested_group_id::text,'friend-invite'),1));
  select i.token into code from private.social_invites i where i.inviter_id=viewer
    and i.group_id is not distinct from requested_group_id
    and i.expires_at>now()+interval '5 minutes' and i.revoked_at is null
    order by i.created_at desc limit 1;
  if code is null then
    code := replace(gen_random_uuid()::text,'-','');
    insert into private.social_invites(token,inviter_id,group_id,expires_at)
      values(code,viewer,requested_group_id,expiry);
  end if;
  return private.resolve_social_invite(code);
end;
$$;
revoke all on function private.create_social_invite(uuid) from public,anon;
grant execute on function private.create_social_invite(uuid) to authenticated;
create or replace function public.create_social_invite(requested_group_id uuid default null)
returns jsonb language sql security invoker set search_path = '' as $$ select private.create_social_invite($1); $$;
revoke all on function public.create_social_invite(uuid) from public,anon;
grant execute on function public.create_social_invite(uuid) to authenticated;

create or replace function private.accept_social_invite(invite_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare invitation jsonb; inviter uuid; group_id uuid; friendship_status text; members uuid[];
begin
  invitation := private.resolve_social_invite(invite_token);
  inviter := (invitation->>'inviter_id')::uuid;
  group_id := (invitation->>'group_id')::uuid;
  if inviter=auth.uid() then raise exception 'This is your own invite. Share it with a friend.' using errcode='22023'; end if;
  friendship_status := private.send_friend_request(inviter);
  if group_id is not null then
    select g.member_ids into members from public.night_groups g where g.id=group_id for update;
    if not found then raise exception 'This group invite is no longer available.' using errcode='22023'; end if;
    if not auth.uid()=any(members) then
      if cardinality(members)>=100 then raise exception 'This group is full.' using errcode='22023'; end if;
      -- Joining is explicit; this does not make private posts visible before friendship acceptance.
      update public.night_groups g set member_ids=members||auth.uid() where g.id=group_id;
    end if;
  end if;
  return jsonb_build_object('inviter_id',inviter,'group_id',group_id,'friendship_status',friendship_status);
end;
$$;
revoke all on function private.accept_social_invite(text) from public,anon;
grant execute on function private.accept_social_invite(text) to authenticated;
create or replace function public.accept_social_invite(invite_token text)
returns jsonb language sql security invoker set search_path = '' as $$ select private.accept_social_invite($1); $$;
revoke all on function public.accept_social_invite(text) from public,anon;
grant execute on function public.accept_social_invite(text) to authenticated;

notify pgrst, 'reload schema';
