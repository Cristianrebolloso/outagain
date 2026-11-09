-- A night group leaves Tonight at 7am. Its invite must expire at the same
-- boundary, not 36 hours after creation (which allowed invisible late joins).
create or replace function private.night_invite_expiry(created_at timestamptz, viewer_time_zone text)
returns timestamptz language plpgsql stable security invoker set search_path = '' as $$
begin
  if viewer_time_zone is null or not exists(
    select 1 from pg_catalog.pg_timezone_names z where z.name=viewer_time_zone
  ) then raise exception 'That time zone is not supported.' using errcode='22023'; end if;
  return (date_trunc('day',(created_at at time zone viewer_time_zone)-interval '7 hours')
    + interval '1 day 7 hours') at time zone viewer_time_zone;
end;
$$;
revoke all on function private.night_invite_expiry(timestamptz,text) from public,anon,authenticated;

-- Keep any already-issued group codes only until their actual night ends.
-- Friend-only links and their 30-day lifetime are unchanged.
update private.social_invites i set expires_at=least(i.expires_at,
  private.night_invite_expiry(g.created_at,coalesce(c.time_zone,'America/Chicago')))
from public.night_groups g left join private.discovery_context c on c.user_id=g.creator_id
where i.group_id=g.id;

-- Replace the unpublished one-parameter signatures rather than overload them:
-- PostgREST must resolve requests with an omitted optional group id unambiguously.
drop function public.create_social_invite(uuid);
drop function private.create_social_invite(uuid);

create function private.create_social_invite(requested_group_id uuid default null, viewer_time_zone text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare viewer uuid := auth.uid(); code text; expiry timestamptz; group_created timestamptz; zone text;
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
    zone := coalesce(viewer_time_zone,(select c.time_zone from private.discovery_context c where c.user_id=viewer),'America/Chicago');
    expiry := private.night_invite_expiry(group_created,zone);
    if expiry<=now() or group_created>now()+interval '1 minute' then
      raise exception 'That night has ended. Start a new group for tonight.' using errcode='22023';
    end if;
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
  elsif requested_group_id is not null then
    update private.social_invites i set expires_at=least(i.expires_at,expiry) where i.token=code;
  end if;
  return private.resolve_social_invite(code);
end;
$$;
revoke all on function private.create_social_invite(uuid,text) from public,anon;
grant execute on function private.create_social_invite(uuid,text) to authenticated;
create function public.create_social_invite(requested_group_id uuid default null, viewer_time_zone text default null)
returns jsonb language sql security invoker set search_path = '' as $$ select private.create_social_invite($1,$2); $$;
revoke all on function public.create_social_invite(uuid,text) from public,anon;
grant execute on function public.create_social_invite(uuid,text) to authenticated;
notify pgrst, 'reload schema';
