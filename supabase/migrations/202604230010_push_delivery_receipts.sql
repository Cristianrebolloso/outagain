-- Push delivery receipts.
--
-- The iOS app and notification triggers already create `notifications` rows
-- for friend requests, accepted requests, friend posts, reactions, and
-- comments. This migration tightens the final leg: every trigger dispatch now
-- has a `push_attempts` row that starts as queued/dispatched and is completed
-- by the edge function with the actual APNs outcome.
--
-- It also fixes a subtle PL/pgSQL name collision in the previous dispatch
-- function: `request_id = request_id` could resolve against the column instead
-- of the pg_net variable. The renamed `net_request_id` below makes the queued
-- request observable every time.

create extension if not exists pg_net;

alter table public.push_attempts
  add column if not exists edge_status_code integer,
  add column if not exists edge_response jsonb,
  add column if not exists delivered_count integer not null default 0,
  add column if not exists failure_count integer not null default 0,
  add column if not exists completed_at timestamptz;

create or replace function public.dispatch_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  target_supabase_url text;
  service_role_key text;
  net_request_id bigint;
  attempt_id uuid;
begin
  target_supabase_url := nullif(current_setting('app.settings.supabase_url', true), '');
  service_role_key := nullif(current_setting('app.settings.supabase_service_role_key', true), '');

  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status
  ) values (
    new.id, new.user_id, new.kind, 'pending'
  )
  returning id into attempt_id;

  if target_supabase_url is null or service_role_key is null then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'missing app.settings.supabase_url or service_role_key',
           completed_at = timezone('utc', now())
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
           completed_at = timezone('utc', now())
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

create or replace function public.debug_push_config()
returns table (
  supabase_url_set boolean,
  service_role_key_set boolean,
  pg_net_installed boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    nullif(current_setting('app.settings.supabase_url', true), '') is not null
      as supabase_url_set,
    nullif(current_setting('app.settings.supabase_service_role_key', true), '') is not null
      as service_role_key_set,
    exists (
      select 1 from pg_extension where extname = 'pg_net'
    ) as pg_net_installed;
$$;

grant execute on function public.debug_push_config() to service_role;
