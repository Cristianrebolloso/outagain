-- dispatch_notification_push declared a PL/pgSQL variable named `dedupe_key`
-- and then used the same identifier inside the VALUES clause of an INSERT into
-- public.notification_push_dedupe (which has a column `dedupe_key`). Postgres
-- raises "column reference \"dedupe_key\" is ambiguous" (SQLSTATE 42702),
-- aborting the transaction. Because the trigger fires on notifications INSERT
-- and notifications are inserted by notify_on_reaction / notify_on_comment /
-- notify_on_post / friend-request triggers, EVERY user write that produces a
-- notification rolls back. Symptom: liking a friend's post optimistically
-- fills the heart, then "instantly" reverts (the REST INSERT 4xx'd within the
-- second). Self-likes work because notify_on_reaction early-returns when
-- recipient_id == new.user_id, so dispatch never runs.
--
-- Fix: rename the variable to `v_dedupe_key` so it can never collide with the
-- column. Function body is otherwise unchanged.

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
    notification_id, recipient_user_id, kind, status
  ) values (
    new.id, new.user_id, new.kind, 'pending'
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
