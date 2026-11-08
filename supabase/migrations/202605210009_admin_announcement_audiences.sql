-- Admin announcement audiences and removable latest-announcement controls.

alter table public.app_announcements
  add column if not exists audience text not null default 'all',
  add column if not exists target_usernames text[];

update public.app_announcements
set audience = 'selected'
where audience = 'all'
  and target_user_ids is not null
  and cardinality(target_user_ids) > 0;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_announcements_audience_check'
      and conrelid = 'public.app_announcements'::regclass
  ) then
    alter table public.app_announcements
      add constraint app_announcements_audience_check
      check (audience in ('all', 'verified', 'selected'));
  end if;
end;
$$;

create or replace function public.admin_create_app_announcement(
  title text,
  message text,
  audience text default 'all',
  target_usernames text[] default '{}'::text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_title text := nullif(trim(coalesce(title, '')), '');
  cleaned_message text := nullif(trim(coalesce(message, '')), '');
  normalized_audience text := lower(nullif(trim(coalesce(audience, 'all')), ''));
  target_ids uuid[];
  normalized_usernames text[];
  requested_count integer := 0;
  matched_count integer := 0;
  inserted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can send app-wide notifications.'
      using errcode = '42501';
  end if;

  if cleaned_title is null then
    raise exception 'Notification title is required.';
  end if;

  if cleaned_message is null then
    raise exception 'Notification message is required.';
  end if;

  if normalized_audience is null then
    normalized_audience := 'all';
  end if;

  if normalized_audience not in ('all', 'verified', 'selected') then
    raise exception 'Unknown notification audience.';
  end if;

  if normalized_audience = 'selected' then
    with requested as (
      select distinct trim(leading '@' from lower(btrim(username))) as username
      from unnest(coalesce(target_usernames, '{}'::text[])) as u(username)
      where nullif(trim(leading '@' from lower(btrim(username))), '') is not null
    )
    select count(*)
    into requested_count
    from requested;

    if requested_count = 0 then
      raise exception 'Enter at least one username.';
    end if;

    with requested as (
      select distinct trim(leading '@' from lower(btrim(username))) as username
      from unnest(coalesce(target_usernames, '{}'::text[])) as u(username)
      where nullif(trim(leading '@' from lower(btrim(username))), '') is not null
    )
    select array_agg(p.id order by p.username), array_agg(p.username order by p.username), count(p.id)
    into target_ids, normalized_usernames, matched_count
    from requested r
    join public.profiles p
      on lower(p.username) = r.username
    where coalesce(p.is_banned, false) = false;

    if requested_count <> matched_count then
      raise exception 'One or more usernames were not found.';
    end if;
  elsif normalized_audience = 'verified' then
    select array_agg(p.id order by p.username), array_agg(p.username order by p.username), count(p.id)
    into target_ids, normalized_usernames, matched_count
    from public.profiles p
    where coalesce(p.is_verified, false) = true
      and coalesce(p.is_banned, false) = false
      and nullif(btrim(coalesce(p.username, '')), '') is not null;

    if coalesce(matched_count, 0) = 0 then
      raise exception 'No verified users found.';
    end if;
  else
    target_ids := null;
    normalized_usernames := null;
  end if;

  update public.app_announcements a
  set is_active = false
  where a.is_active
    and coalesce(a.audience, 'all') = normalized_audience
    and (
      normalized_audience in ('all', 'verified')
      or (
        coalesce(a.target_user_ids, '{}'::uuid[]) @> coalesce(target_ids, '{}'::uuid[])
        and coalesce(a.target_user_ids, '{}'::uuid[]) <@ coalesce(target_ids, '{}'::uuid[])
      )
    );

  insert into public.app_announcements (
    title,
    message,
    target_user_ids,
    audience,
    target_usernames,
    starts_at,
    expires_at,
    created_by
  )
  values (
    cleaned_title,
    cleaned_message,
    target_ids,
    normalized_audience,
    normalized_usernames,
    timezone('utc', now()),
    null,
    auth.uid()
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.admin_create_app_announcement(text, text, text, text[]) from public;
revoke all on function public.admin_create_app_announcement(text, text, text, text[]) from anon;
grant execute on function public.admin_create_app_announcement(text, text, text, text[]) to authenticated;

create or replace function public.admin_latest_app_announcements(
  limit_count integer default 5
)
returns table (
  announcement_id uuid,
  title text,
  message text,
  audience text,
  target_usernames text[],
  recipient_count integer,
  is_active boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with recent as (
    select
      a.id,
      a.title,
      a.message,
      coalesce(
        nullif(a.audience, ''),
        case
          when a.target_user_ids is not null and cardinality(a.target_user_ids) > 0 then 'selected'
          else 'all'
        end
      ) as resolved_audience,
      a.target_user_ids,
      a.target_usernames,
      a.is_active,
      a.created_at
    from public.app_announcements a
    where public.is_app_admin(auth.uid())
    order by a.created_at desc, a.id desc
    limit least(greatest(coalesce(limit_count, 5), 1), 20)
  )
  select
    r.id as announcement_id,
    r.title,
    r.message,
    r.resolved_audience as audience,
    case
      when r.target_usernames is not null and cardinality(r.target_usernames) > 0 then r.target_usernames
      else coalesce((
        select array_agg(p.username order by p.username)
        from unnest(coalesce(r.target_user_ids, '{}'::uuid[])) as target(id)
        join public.profiles p on p.id = target.id
      ), '{}'::text[])
    end as target_usernames,
    case
      when r.resolved_audience = 'all' then (
        select count(*)::integer
        from public.profiles p
        where coalesce(p.is_banned, false) = false
          and nullif(btrim(coalesce(p.username, '')), '') is not null
      )
      else coalesce(cardinality(r.target_user_ids), 0)
    end as recipient_count,
    r.is_active,
    r.created_at
  from recent r;
$$;

revoke all on function public.admin_latest_app_announcements(integer) from public;
revoke all on function public.admin_latest_app_announcements(integer) from anon;
grant execute on function public.admin_latest_app_announcements(integer) to authenticated;

create or replace function public.admin_deactivate_app_announcement(
  announcement_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_id uuid := announcement_id;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can remove app-wide notifications.'
      using errcode = '42501';
  end if;

  update public.app_announcements a
  set is_active = false
  where a.id = target_id;

  if not found then
    raise exception 'Notification was not found.';
  end if;
end;
$$;

revoke all on function public.admin_deactivate_app_announcement(uuid) from public;
revoke all on function public.admin_deactivate_app_announcement(uuid) from anon;
grant execute on function public.admin_deactivate_app_announcement(uuid) to authenticated;
