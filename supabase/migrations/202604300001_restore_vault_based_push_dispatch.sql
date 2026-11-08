-- Restore vault-backed push dispatch configuration.
--
-- Hosted Supabase no longer accepts arbitrary `app.settings.*` overrides via
-- postgres-config, and many projects also cannot `ALTER DATABASE` from the
-- dashboard SQL editor. Push dispatch should therefore read the service-role
-- key from Supabase Vault instead of relying on custom GUCs.
--
-- The project URL is not secret, so we inline it here. The service-role key
-- remains secret and must exist in Vault under the name:
--   supabase_service_role_key

create extension if not exists pg_net;

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
begin
  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status
  ) values (
    new.id, new.user_id, new.kind, 'pending'
  )
  returning id into attempt_id;

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
language plpgsql
stable
security definer
set search_path = public, extensions, vault
as $$
declare
  has_service_role_key boolean := false;
begin
  begin
    select exists(
      select 1
      from vault.decrypted_secrets
      where name = 'supabase_service_role_key'
        and nullif(decrypted_secret, '') is not null
    )
    into has_service_role_key;
  exception when others then
    has_service_role_key := false;
  end;

  return query
  select
    true as supabase_url_set,
    has_service_role_key as service_role_key_set,
    exists (
      select 1 from pg_extension where extname = 'pg_net'
    ) as pg_net_installed;
end;
$$;

grant execute on function public.debug_push_config() to service_role;
