-- Server-side abuse throttles and short-window push dedupe.
--
-- These limits are intentionally generous for normal use but stop API-speed
-- abuse from one authenticated account:
--   * posts:           20 / hour
--   * comments:       120 / hour
--   * post reactions: 180 / hour
--   * comment likes:  180 / hour
--   * friendships:     30 / hour
--   * reports:         20 / hour
--
-- Push dedupe uses a two-minute signature window. Notification rows still
-- land in-app; duplicate APNs dispatches are skipped and recorded in
-- push_attempts for diagnostics.

create index if not exists comments_author_created_at_idx
  on public.comments (author_id, created_at desc);

create index if not exists reactions_user_created_at_idx
  on public.reactions (user_id, created_at desc);

create index if not exists friendships_user_created_at_idx
  on public.friendships (user_id, created_at desc);

create index if not exists content_reports_reporter_created_at_idx
  on public.content_reports (reporter_id, created_at desc);

-- Existing migrations already create comment_likes_user_created_at_idx.
create index if not exists comment_likes_user_created_at_idx
  on public.comment_likes (user_id, created_at desc);

create index if not exists notifications_push_dedupe_lookup_idx
  on public.notifications (
    user_id,
    actor_id,
    kind,
    post_id,
    comment_id,
    created_at desc
  );

create or replace function public.enforce_hourly_insert_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_column text := tg_argv[0];
  hourly_limit integer := tg_argv[1]::integer;
  action_label text := tg_argv[2];
  actor_id uuid;
  recent_count integer := 0;
  now_utc timestamptz := timezone('utc', now());
begin
  -- Migrations, seed scripts, and service-role maintenance jobs need to be
  -- able to backfill data without tripping user-facing abuse limits.
  if coalesce(auth.role(), current_user) in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  -- Client-supplied created_at would let a malicious caller backdate rows out
  -- of the one-hour window. Every limited authenticated insert uses server
  -- time from this point forward.
  new.created_at = now_utc;

  if auth.uid() is null then
    return new;
  end if;

  actor_id := nullif(to_jsonb(new) ->> actor_column, '')::uuid;
  if actor_id is null then
    return new;
  end if;

  execute format(
    'select count(*)::integer
       from %s
      where %I = $1
        and created_at >= $2',
    tg_relid::regclass,
    actor_column
  )
  using actor_id, now_utc - interval '1 hour'
  into recent_count;

  if recent_count >= hourly_limit then
    raise exception 'Too many % in the last hour. Please slow down.', action_label
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists posts_rate_limit_insert on public.posts;
create trigger posts_rate_limit_insert
before insert on public.posts
for each row
execute function public.enforce_hourly_insert_rate_limit('author_id', '20', 'posts');

drop trigger if exists comments_rate_limit_insert on public.comments;
create trigger comments_rate_limit_insert
before insert on public.comments
for each row
execute function public.enforce_hourly_insert_rate_limit('author_id', '120', 'comments');

drop trigger if exists reactions_rate_limit_insert on public.reactions;
create trigger reactions_rate_limit_insert
before insert on public.reactions
for each row
execute function public.enforce_hourly_insert_rate_limit('user_id', '180', 'reactions');

drop trigger if exists comment_likes_rate_limit_insert on public.comment_likes;
create trigger comment_likes_rate_limit_insert
before insert on public.comment_likes
for each row
execute function public.enforce_hourly_insert_rate_limit('user_id', '180', 'comment likes');

drop trigger if exists friendships_rate_limit_insert on public.friendships;
create trigger friendships_rate_limit_insert
before insert on public.friendships
for each row
execute function public.enforce_hourly_insert_rate_limit('user_id', '30', 'friend requests');

drop trigger if exists content_reports_rate_limit_insert on public.content_reports;
create trigger content_reports_rate_limit_insert
before insert on public.content_reports
for each row
execute function public.enforce_hourly_insert_rate_limit('reporter_id', '20', 'reports');

create table if not exists public.notification_push_dedupe (
  dedupe_key text primary key,
  notification_id uuid references public.notifications (id) on delete set null,
  last_dispatched_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists notification_push_dedupe_last_dispatched_at_idx
  on public.notification_push_dedupe (last_dispatched_at desc);

alter table public.notification_push_dedupe enable row level security;

drop policy if exists "notification_push_dedupe service role only" on public.notification_push_dedupe;
create policy "notification_push_dedupe service role only"
on public.notification_push_dedupe
for all
to authenticated
using (false)
with check (false);

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
  dedupe_key text;
  should_dispatch boolean := true;
begin
  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status
  ) values (
    new.id, new.user_id, new.kind, 'pending'
  )
  returning id into attempt_id;

  dedupe_key := md5(concat_ws(
    '|',
    new.user_id::text,
    coalesce(new.actor_id::text, ''),
    coalesce(new.kind, ''),
    coalesce(new.post_id::text, ''),
    coalesce(new.comment_id::text, ''),
    coalesce(new.title, ''),
    coalesce(new.detail, '')
  ));

  -- Opportunistic cleanup keeps the dedupe table tiny without requiring a
  -- scheduler. At app scale this runs rarely; duplicates still check fast via
  -- the primary key.
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
      dedupe_key,
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

drop trigger if exists notifications_dispatch_push on public.notifications;
create trigger notifications_dispatch_push
after insert on public.notifications
for each row
execute procedure public.dispatch_notification_push();
