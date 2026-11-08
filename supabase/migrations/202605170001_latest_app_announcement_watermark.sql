-- Latest-only app announcements with a per-user eligibility watermark.
--
-- Requirements:
--   1. A newly published announcement replaces any older unseen announcement
--      for the same viewer, so users only ever see the newest relevant one.
--   2. Brand-new users do not see announcements that existed before they
--      completed onboarding.

alter table public.profiles
  add column if not exists app_announcements_started_at timestamptz;

create or replace function public.set_app_announcements_started_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is not null
     and btrim(new.username) <> ''
     and new.app_announcements_started_at is null
  then
    if tg_op = 'INSERT' then
      new.app_announcements_started_at = timezone('utc', now());
    elsif old.username is null or btrim(coalesce(old.username, '')) = '' then
      new.app_announcements_started_at = timezone('utc', now());
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_set_app_announcements_started_at on public.profiles;
create trigger profiles_set_app_announcements_started_at
before insert or update of username on public.profiles
for each row
execute procedure public.set_app_announcements_started_at();

create or replace function public.unseen_app_announcements(limit_count integer default 1)
returns table (
  id uuid,
  title text,
  message text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with viewer as (
    select
      p.id,
      coalesce(p.app_announcements_started_at, p.created_at) as eligible_after
    from public.profiles p
    where p.id = auth.uid()
      and nullif(btrim(coalesce(p.username, '')), '') is not null
  ),
  latest_matching as (
    select
      a.id,
      a.title,
      a.message,
      a.created_at,
      a.is_active,
      a.starts_at,
      a.expires_at
    from public.app_announcements a
    join viewer v on true
    where a.created_at > v.eligible_after
      and (
        a.target_user_ids is null
        or cardinality(a.target_user_ids) = 0
        or v.id = any(a.target_user_ids)
      )
    order by a.created_at desc, a.id desc
    limit 1
  )
  select
    a.id,
    a.title,
    a.message,
    a.created_at
  from latest_matching a
  join viewer v on true
  where a.is_active
    and a.starts_at <= now()
    and (a.expires_at is null or a.expires_at > now())
    and not exists (
      select 1
      from public.app_announcement_receipts r
      where r.announcement_id = a.id
        and r.user_id = v.id
    )
  limit least(greatest(coalesce(limit_count, 1), 1), 1);
$$;

revoke all on function public.unseen_app_announcements(integer) from public;
revoke all on function public.unseen_app_announcements(integer) from anon;
grant execute on function public.unseen_app_announcements(integer) to authenticated;

create or replace function public.create_app_announcement(
  p_title text,
  p_message text,
  p_target_usernames text[] default null,
  p_starts_at timestamptz default now(),
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_ids uuid[];
  requested_count integer := 0;
  matched_count integer := 0;
  inserted_id uuid;
begin
  if nullif(trim(p_title), '') is null then
    raise exception 'Announcement title is required.';
  end if;

  if nullif(trim(p_message), '') is null then
    raise exception 'Announcement message is required.';
  end if;

  if p_target_usernames is not null and cardinality(p_target_usernames) > 0 then
    with requested as (
      select distinct lower(trim(username)) as username
      from unnest(p_target_usernames) as u(username)
      where nullif(trim(username), '') is not null
    )
    select count(*)
    into requested_count
    from requested;

    if requested_count = 0 then
      raise exception 'At least one target username is required.';
    end if;

    with requested as (
      select distinct lower(trim(username)) as username
      from unnest(p_target_usernames) as u(username)
      where nullif(trim(username), '') is not null
    )
    select array_agg(p.id order by p.id), count(p.id)
    into target_ids, matched_count
    from requested r
    join public.profiles p on lower(p.username) = r.username;

    if requested_count <> matched_count then
      raise exception 'One or more target usernames were not found.';
    end if;
  end if;

  update public.app_announcements a
  set is_active = false
  where a.is_active
    and (
      (
        target_ids is null
        and (a.target_user_ids is null or cardinality(a.target_user_ids) = 0)
      )
      or (
        target_ids is not null
        and coalesce(a.target_user_ids, '{}'::uuid[]) @> target_ids
        and coalesce(a.target_user_ids, '{}'::uuid[]) <@ target_ids
      )
    );

  insert into public.app_announcements (
    title,
    message,
    target_user_ids,
    starts_at,
    expires_at,
    created_by
  )
  values (
    trim(p_title),
    trim(p_message),
    target_ids,
    coalesce(p_starts_at, now()),
    p_expires_at,
    auth.uid()
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.create_app_announcement(text, text, text[], timestamptz, timestamptz) from public;
revoke all on function public.create_app_announcement(text, text, text[], timestamptz, timestamptz) from anon;
revoke all on function public.create_app_announcement(text, text, text[], timestamptz, timestamptz) from authenticated;
grant execute on function public.create_app_announcement(text, text, text[], timestamptz, timestamptz) to service_role;
