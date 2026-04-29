-- Notification fan-out: every notification row inserted into public.notifications
-- triggers an async HTTP call to the notify-activity edge function, which
-- delivers an APNs push to each device the recipient has registered.
--
-- We use pg_net so the HTTP call does not block the originating write. If the
-- edge function is unavailable, the in-app notification row still exists and
-- the user will see it on next refresh; the push just doesn't land.
--
-- The Supabase URL and service role key are stored in the vault and read at
-- runtime via vault.decrypted_secrets. This avoids the need for ALTER DATABASE
-- (which requires superuser) while keeping the secret out of the function body.

create extension if not exists pg_net;

create or replace function public.dispatch_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  supabase_url text := 'https://xissvzlusznqpxvwnwpu.supabase.co';
  service_key text;
  request_id bigint;
begin
  -- Read the service role key from Supabase Vault so it never appears in
  -- plaintext in the migration. The secret must be stored in the Vault with
  -- the name 'supabase_service_role_key' (one-time setup via the dashboard:
  -- Project Settings -> Vault -> New Secret).
  begin
    select decrypted_secret into service_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;
  exception when others then
    -- Vault not available (local dev) — skip push silently.
    return new;
  end;

  if service_key is null then
    return new;
  end if;

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

  return new;
exception when others then
  -- Never let a push dispatch failure block the write that caused it.
  -- The in-app notification row is still persisted; we just lost the push.
  return new;
end;
$$;

drop trigger if exists notifications_dispatch_push on public.notifications;
create trigger notifications_dispatch_push
after insert on public.notifications
for each row
execute procedure public.dispatch_notification_push();

-- While we're here, make the service_role the only writer to the devices
-- table via the edge function flow where possible. Users can still upsert
-- their own tokens from the iOS client; that's how the existing policy
-- works and we preserve it.
