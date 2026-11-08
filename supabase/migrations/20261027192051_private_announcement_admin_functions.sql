-- Keep privileged fan-out behind private functions. Public RPCs use the
-- caller's privileges and delegate to the same explicit admin checks.
create schema if not exists private;
grant usage on schema private to authenticated, service_role;

alter function public.admin_publish_announcement(uuid, text, text, text, text[], text) set schema private;
alter function private.admin_publish_announcement(uuid, text, text, text, text[], text) set search_path = '';
revoke all on function private.admin_publish_announcement(uuid, text, text, text, text[], text) from public, anon;
grant execute on function private.admin_publish_announcement(uuid, text, text, text, text[], text) to authenticated;

create function public.admin_publish_announcement(
  request_id uuid, title text, message text, audience text default 'all',
  target_usernames text[] default '{}'::text[], delivery text default 'in_app'
)
returns uuid language sql security invoker set search_path = ''
as $$ select private.admin_publish_announcement($1, $2, $3, $4, $5, $6); $$;
revoke all on function public.admin_publish_announcement(uuid, text, text, text, text[], text) from public, anon;
grant execute on function public.admin_publish_announcement(uuid, text, text, text, text[], text) to authenticated;

alter function public.admin_announcement_history(integer) set schema private;
alter function private.admin_announcement_history(integer) set search_path = '';
revoke all on function private.admin_announcement_history(integer) from public, anon;
grant execute on function private.admin_announcement_history(integer) to authenticated;

create function public.admin_announcement_history(limit_count integer default 5)
returns table (
  announcement_id uuid, title text, message text, audience text,
  target_usernames text[], recipient_count integer, is_active boolean,
  created_at timestamptz, delivery text, push_recipient_count integer,
  push_accepted_count integer, push_failure_count integer,
  push_skipped_count integer, push_pending_count integer
)
language sql stable security invoker set search_path = ''
as $$ select * from private.admin_announcement_history($1); $$;
revoke all on function public.admin_announcement_history(integer) from public, anon;
grant execute on function public.admin_announcement_history(integer) to authenticated;
