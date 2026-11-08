-- Server-driven app announcements.
--
-- Use this for launch-time news, maintenance notices, or targeted messages
-- without shipping a new app build. The app fetches unseen announcements on
-- bootstrap and writes one receipt per viewer when they tap Dismiss.
--
-- Publish to everyone:
--   select public.create_app_announcement(
--     'Weekend update',
--     'New profile stats are live. Go see your longest bender.'
--   );
--
-- Publish to specific usernames:
--   select public.create_app_announcement(
--     'Cristian only',
--     'This message only shows for @cristian.',
--     array['cristian']
--   );

create table if not exists public.app_announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 80),
  message text not null check (char_length(trim(message)) between 1 and 1000),
  target_user_ids uuid[] default null,
  is_active boolean not null default true,
  starts_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint app_announcements_expiry_after_start
    check (expires_at is null or expires_at > starts_at)
);

-- Some early remote environments had a hand-created app_announcements table.
-- `create table if not exists` leaves that older shape untouched, so make the
-- migration additive before creating indexes/policies/functions that reference
-- these columns.
alter table public.app_announcements
  add column if not exists target_user_ids uuid[] default null,
  add column if not exists is_active boolean not null default true,
  add column if not exists starts_at timestamptz not null default now(),
  add column if not exists expires_at timestamptz,
  add column if not exists created_by uuid references public.profiles(id) on delete set null,
  add column if not exists created_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_announcements_expiry_after_start'
      and conrelid = 'public.app_announcements'::regclass
  ) then
    alter table public.app_announcements
      add constraint app_announcements_expiry_after_start
      check (expires_at is null or expires_at > starts_at);
  end if;
end;
$$;

create index if not exists app_announcements_active_window_idx
  on public.app_announcements (is_active, starts_at desc, expires_at);

create index if not exists app_announcements_target_user_ids_gin_idx
  on public.app_announcements using gin (target_user_ids);

create table if not exists public.app_announcement_receipts (
  announcement_id uuid not null references public.app_announcements(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

create index if not exists app_announcement_receipts_user_seen_idx
  on public.app_announcement_receipts (user_id, seen_at desc);

alter table public.app_announcements enable row level security;
alter table public.app_announcement_receipts enable row level security;

drop policy if exists "active announcements readable by targets" on public.app_announcements;
create policy "active announcements readable by targets"
on public.app_announcements
for select
to authenticated
using (
  is_active
  and starts_at <= now()
  and (expires_at is null or expires_at > now())
  and (
    target_user_ids is null
    or cardinality(target_user_ids) = 0
    or auth.uid() = any(target_user_ids)
  )
);

drop policy if exists "users read own announcement receipts" on public.app_announcement_receipts;
create policy "users read own announcement receipts"
on public.app_announcement_receipts
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "users insert own announcement receipts" on public.app_announcement_receipts;
create policy "users insert own announcement receipts"
on public.app_announcement_receipts
for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "users update own announcement receipts" on public.app_announcement_receipts;
create policy "users update own announcement receipts"
on public.app_announcement_receipts
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop function if exists public.unseen_app_announcements(integer);

create or replace function public.unseen_app_announcements(limit_count integer default 5)
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
  select
    a.id,
    a.title,
    a.message,
    a.created_at
  from public.app_announcements a
  where a.is_active
    and a.starts_at <= now()
    and (a.expires_at is null or a.expires_at > now())
    and (
      a.target_user_ids is null
      or cardinality(a.target_user_ids) = 0
      or auth.uid() = any(a.target_user_ids)
    )
    and not exists (
      select 1
      from public.app_announcement_receipts r
      where r.announcement_id = a.id
        and r.user_id = auth.uid()
    )
  order by a.created_at desc
  limit least(greatest(coalesce(limit_count, 5), 1), 10);
$$;

revoke all on function public.unseen_app_announcements(integer) from public;
revoke all on function public.unseen_app_announcements(integer) from anon;
grant execute on function public.unseen_app_announcements(integer) to authenticated;

create or replace function public.mark_app_announcement_seen(announcement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  viewer_id uuid := auth.uid();
begin
  if viewer_id is null then
    raise exception 'Not authenticated.';
  end if;

  insert into public.app_announcement_receipts (announcement_id, user_id, seen_at)
  select a.id, viewer_id, now()
  from public.app_announcements a
  where a.id = announcement_id
    and (
      a.target_user_ids is null
      or cardinality(a.target_user_ids) = 0
      or viewer_id = any(a.target_user_ids)
    )
  on conflict (announcement_id, user_id)
  do update set seen_at = excluded.seen_at;
end;
$$;

revoke all on function public.mark_app_announcement_seen(uuid) from public;
revoke all on function public.mark_app_announcement_seen(uuid) from anon;
grant execute on function public.mark_app_announcement_seen(uuid) to authenticated;

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
    select array_agg(p.id order by p.username), count(p.id)
    into target_ids, matched_count
    from requested r
    join public.profiles p on lower(p.username) = r.username;

    if requested_count <> matched_count then
      raise exception 'One or more target usernames were not found.';
    end if;
  end if;

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
