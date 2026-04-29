-- Push attempt logging + diagnostics.
--
-- The dispatch chain is client -> postgres trigger -> pg_net -> edge function
-- -> APNs, and three of those four hops can fail silently. Until now every
-- failure returned no observable signal because `dispatch_notification_push`
-- swallowed exceptions with `exception when others then return new` (a
-- deliberate choice to never block a write; the cost is invisibility).
--
-- This migration attacks the invisibility directly:
--
--   1. A `public.push_attempts` table captures every dispatch invocation
--      with: whether it was skipped (config missing), the pg_net request_id
--      returned by http_post, the edge-function response status (backfilled
--      asynchronously by the edge function), and the last error.
--
--   2. `dispatch_notification_push` now records an attempt row BEFORE the
--      http_post, so even if pg_net itself throws we have a breadcrumb. The
--      exception handler records the error string into the attempt row
--      instead of silently returning.
--
--   3. `public.debug_push_config()` is callable from SQL editor to verify
--      the two settings that most commonly break in a fresh environment
--      (supabase_url, service_role_key). No secret values are leaked — only
--      a boolean indicating presence.
--
-- Operational note: push_attempts grows unbounded if ignored. In production
-- schedule a daily job to delete rows older than 14 days; for a dev app
-- the table will stay small enough that this doesn't matter yet.

create table if not exists public.push_attempts (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid references public.notifications (id) on delete set null,
  recipient_user_id uuid,
  kind text,
  request_id bigint,
  status text not null default 'pending',   -- pending | dispatched | skipped | errored
  skip_reason text,
  error_message text,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists push_attempts_notification_id_idx
  on public.push_attempts (notification_id);
create index if not exists push_attempts_created_at_idx
  on public.push_attempts (created_at desc);

-- Service role is the only expected writer/reader for this table. Clients
-- do not need access; the admin uses the SQL editor under service role.
alter table public.push_attempts enable row level security;
drop policy if exists "push_attempts service role only" on public.push_attempts;
create policy "push_attempts service role only"
on public.push_attempts
for all
to authenticated
using (false)
with check (false);


-- Rewrite the dispatch function so every path leaves a trace.
create or replace function public.dispatch_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  supabase_url text;
  service_key text;
  request_id bigint;
  attempt_id uuid;
begin
  supabase_url := current_setting('app.settings.supabase_url', true);
  service_key := current_setting('app.settings.supabase_service_role_key', true);

  -- Record the attempt up-front so a later pg_net crash still leaves a row.
  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status
  ) values (
    new.id, new.user_id, new.kind, 'pending'
  )
  returning id into attempt_id;

  if supabase_url is null or service_key is null then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'missing app.settings.supabase_url or service_role_key'
     where id = attempt_id;
    return new;
  end if;

  begin
    select net.http_post(
      url := supabase_url || '/functions/v1/notify-activity',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || service_key
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
    ) into request_id;

    update public.push_attempts
       set status = 'dispatched',
           request_id = request_id
     where id = attempt_id;
  exception when others then
    update public.push_attempts
       set status = 'errored',
           error_message = left(sqlerrm, 500)
     where id = attempt_id;
    -- Still do not block the write that caused this.
  end;

  return new;
end;
$$;

-- Helper for SQL-editor verification. Returns booleans only, never secrets.
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
    current_setting('app.settings.supabase_url', true) is not null
      and current_setting('app.settings.supabase_url', true) <> ''
      as supabase_url_set,
    current_setting('app.settings.supabase_service_role_key', true) is not null
      and current_setting('app.settings.supabase_service_role_key', true) <> ''
      as service_role_key_set,
    exists (
      select 1 from pg_extension where extname = 'pg_net'
    ) as pg_net_installed;
$$;

grant execute on function public.debug_push_config() to service_role;


-- Self-test: insert a notification addressed to the calling user. The
-- existing dispatch trigger fires afterward and the push attempt lands in
-- public.push_attempts, so this single RPC exercises the full chain.
--
-- Guarded so the calling user can only insert rows for themselves (no
-- reaching across the graph). Safe to ship in Release builds even though
-- the client only calls it from DEBUG — an attacker who invokes it gains
-- nothing beyond a notification for their own account.
create or replace function public.send_self_test_notification()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is null — sign-in required';
  end if;

  insert into public.notifications (user_id, actor_id, kind, title, detail)
  values (
    auth.uid(),
    auth.uid(),
    'friendPost',
    'Test push',
    'If this shows as a banner, the APNs chain is healthy.'
  )
  returning id into new_id;

  return new_id;
end;
$$;

grant execute on function public.send_self_test_notification() to authenticated;
