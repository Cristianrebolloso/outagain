-- Custom admin push announcements, preserving the existing in-app channel.
-- No announcements are created by this migration.
create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  announcements_enabled boolean not null default true
);
alter table public.notification_preferences enable row level security;
grant select, insert, update on public.notification_preferences to authenticated;
grant all on public.notification_preferences to service_role;
create policy "read own notification preferences" on public.notification_preferences
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "insert own notification preferences" on public.notification_preferences
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "update own notification preferences" on public.notification_preferences
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

alter table public.app_announcements
  add column delivery text not null default 'in_app' check (delivery in ('in_app', 'push', 'both')),
  add column push_recipient_count integer not null default 0;
alter table public.notifications
  add column announcement_id uuid references public.app_announcements(id) on delete set null;
create index notifications_announcement_id_idx on public.notifications(announcement_id)
  where announcement_id is not null;

-- Keep delivery history linked even when recipients clear their Activity list.
alter table public.push_attempts
  add column announcement_id uuid references public.app_announcements(id) on delete set null;
create index push_attempts_announcement_id_idx on public.push_attempts(announcement_id)
  where announcement_id is not null;

create or replace function public.dispatch_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  target_supabase_url text := 'https://xissvzlusznqpxvwnwpu.supabase.co';
  service_role_key text;
  net_request_id bigint;
  attempt_id uuid;
  now_utc timestamptz := timezone('utc', now());
  v_dedupe_key text;
  should_dispatch boolean := true;
begin
  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status, announcement_id
  ) values (
    new.id, new.user_id, new.kind, 'pending', new.announcement_id
  )
  returning id into attempt_id;

  v_dedupe_key := md5(concat_ws(
    '|',
    new.user_id::text,
    coalesce(new.actor_id::text, ''),
    coalesce(new.kind, ''),
    coalesce(new.post_id::text, ''),
    coalesce(new.comment_id::text, ''),
    coalesce(new.title, ''),
    coalesce(new.detail, '')
  ));

  if random() < 0.02 then
    delete from public.notification_push_dedupe
    where last_dispatched_at < now_utc - interval '1 day';
  end if;

  with upserted as (
    insert into public.notification_push_dedupe (
      dedupe_key,
      notification_id,
      last_dispatched_at
    ) values (
      v_dedupe_key,
      new.id,
      now_utc
    )
    on conflict (dedupe_key) do update
      set last_dispatched_at = case
            when public.notification_push_dedupe.last_dispatched_at
                   < excluded.last_dispatched_at - interval '2 minutes'
            then excluded.last_dispatched_at
            else public.notification_push_dedupe.last_dispatched_at
          end,
          notification_id = case
            when public.notification_push_dedupe.last_dispatched_at
                   < excluded.last_dispatched_at - interval '2 minutes'
            then excluded.notification_id
            else public.notification_push_dedupe.notification_id
          end
    returning notification_id = new.id as can_dispatch
  )
  select can_dispatch into should_dispatch
  from upserted;

  if should_dispatch is distinct from true then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'duplicate push notification within 2 minutes',
           completed_at = now_utc
     where id = attempt_id;
    return new;
  end if;

  begin
    select decrypted_secret into service_role_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;
  exception when others then
    service_role_key := null;
  end;

  if service_role_key is null or service_role_key = '' then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'missing vault secret supabase_service_role_key',
           completed_at = now_utc
     where id = attempt_id;
    return new;
  end if;

  begin
    select net.http_post(
      url := target_supabase_url || '/functions/v1/notify-activity',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || service_role_key
      ),
      body := jsonb_build_object(
        'notificationId', new.id,
        'recipientUserId', new.user_id,
        'actorUserId', new.actor_id,
        'kind', new.kind,
        'title', new.title,
        'body', new.detail,
        'postId', new.post_id,
        'commentId', new.comment_id
      )
    ) into net_request_id;

    update public.push_attempts
       set status = 'dispatched',
           request_id = net_request_id
     where id = attempt_id;
  exception when others then
    update public.push_attempts
       set status = 'errored',
           error_message = left(sqlerrm, 500),
           completed_at = now_utc
     where id = attempt_id;
  end;

  return new;
end;
$$;

-- Push-only sends must never become launch pop-ups, including on old apps.
drop policy "active announcements readable by targets" on public.app_announcements;
create policy "active announcements readable by targets" on public.app_announcements
  for select to authenticated using (
    delivery in ('in_app', 'both') and is_active and starts_at <= now()
    and (expires_at is null or expires_at > now())
    and (target_user_ids is null or cardinality(target_user_ids) = 0 or (select auth.uid()) = any(target_user_ids))
  );

create or replace function public.admin_publish_announcement(
  request_id uuid,
  title text,
  message text,
  audience text default 'all',
  target_usernames text[] default '{}'::text[],
  delivery text default 'in_app'
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
  normalized_delivery text := lower(trim(coalesce(delivery, 'in_app')));
  queued_count integer := 0;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can send app-wide notifications.'
      using errcode = '42501';
  end if;

  if request_id is null then
    raise exception 'A request ID is required.';
  end if;

  -- Serialize sends by this administrator. A retry reuses the same ID and
  -- returns the previous result without inserting or dispatching again.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 9271));
  if exists (select 1 from public.app_announcements a where a.id = request_id and a.created_by = auth.uid()) then
    return request_id;
  end if;

  if normalized_delivery not in ('in_app', 'push', 'both') then
    raise exception 'Unknown notification delivery method.';
  end if;
  if normalized_delivery in ('push', 'both') and
     (char_length(cleaned_title) > 100 or char_length(cleaned_message) > 500) then
    raise exception 'Push titles must be 100 characters or fewer and messages 500 characters or fewer.';
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
    and normalized_delivery in ('in_app', 'both')
    and a.delivery in ('in_app', 'both')
    and coalesce(a.audience, 'all') = normalized_audience
    and (
      normalized_audience in ('all', 'verified')
      or (
        coalesce(a.target_user_ids, '{}'::uuid[]) @> coalesce(target_ids, '{}'::uuid[])
        and coalesce(a.target_user_ids, '{}'::uuid[]) <@ coalesce(target_ids, '{}'::uuid[])
      )
    );

  insert into public.app_announcements (
    id,
    delivery,
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
    request_id,
    normalized_delivery,
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

  if normalized_delivery in ('push', 'both') then
    insert into public.notifications (user_id, kind, title, detail, announcement_id)
    select p.id, 'announcement', cleaned_title, cleaned_message, inserted_id
    from public.profiles p
    left join public.notification_preferences pref on pref.user_id = p.id
    where not coalesce(p.is_banned, false)
      and nullif(btrim(coalesce(p.username, '')), '') is not null
      and (target_ids is null or p.id = any(target_ids))
      and coalesce(pref.announcements_enabled, true)
      and exists (select 1 from public.devices d where d.user_id = p.id);
    get diagnostics queued_count = row_count;
    update public.app_announcements a
    set push_recipient_count = queued_count
    where a.id = inserted_id;
  end if;

  return inserted_id;
end;
$$;

revoke all on function public.admin_publish_announcement(uuid, text, text, text, text[], text) from public;
revoke all on function public.admin_publish_announcement(uuid, text, text, text, text[], text) from anon;
grant execute on function public.admin_publish_announcement(uuid, text, text, text, text[], text) to authenticated;

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
    where a.delivery in ('in_app', 'both')
      and a.created_at > v.eligible_after
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


-- The old history RPC stays compatible with existing app versions.
create or replace function public.admin_announcement_history(limit_count integer default 5)
returns table (
  announcement_id uuid, title text, message text, audience text,
  target_usernames text[], recipient_count integer, is_active boolean,
  created_at timestamptz, delivery text, push_recipient_count integer,
  push_accepted_count integer, push_failure_count integer,
  push_skipped_count integer, push_pending_count integer
)
language sql stable security definer set search_path = public
as $$
  select h.*, a.delivery, a.push_recipient_count,
    coalesce(s.accepted, 0)::integer, coalesce(s.failed, 0)::integer,
    coalesce(s.skipped, 0)::integer, coalesce(s.pending, 0)::integer
  from public.admin_latest_app_announcements(limit_count) h
  join public.app_announcements a on a.id = h.announcement_id
  left join lateral (
    select sum(pa.delivered_count) as accepted,
      sum(greatest(pa.failure_count, case when pa.status = 'errored' then 1 else 0 end)) as failed,
      count(*) filter (where pa.status = 'skipped') as skipped,
      count(*) filter (where pa.status in ('pending', 'dispatched')) as pending
    from public.push_attempts pa
    where pa.announcement_id = a.id
  ) s on true
  where auth.uid() is not null and public.is_app_admin(auth.uid())
  order by h.created_at desc, h.announcement_id desc;
$$;
revoke all on function public.admin_announcement_history(integer) from public, anon;
grant execute on function public.admin_announcement_history(integer) to authenticated;
