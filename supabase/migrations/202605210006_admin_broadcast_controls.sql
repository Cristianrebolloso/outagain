-- Admin-controlled maintenance mode and app-wide in-app announcements.
--
-- These RPCs are callable from the iOS app by authenticated users, but each
-- call is guarded by public.is_app_admin(auth.uid()) so only @admin can mutate
-- app-wide state.

create or replace function public.admin_set_app_maintenance_config(
  enabled boolean,
  title text,
  message text
)
returns table (
  key text,
  value text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_title text := nullif(trim(coalesce(title, '')), '');
  cleaned_message text := nullif(trim(coalesce(message, '')), '');
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can manage maintenance mode.'
      using errcode = '42501';
  end if;

  if cleaned_title is null then
    raise exception 'Maintenance title is required.';
  end if;

  if cleaned_message is null then
    raise exception 'Maintenance message is required.';
  end if;

  insert into public.app_config (key, value)
  values
    ('maintenance_mode_enabled', case when coalesce(enabled, false) then 'true' else 'false' end),
    ('maintenance_title', cleaned_title),
    ('maintenance_message', cleaned_message)
  on conflict (key) do update
  set value = excluded.value;

  return query
  select c.key, c.value
  from public.app_config c
  where c.key in ('maintenance_mode_enabled', 'maintenance_title', 'maintenance_message')
  order by c.key;
end;
$$;

revoke all on function public.admin_set_app_maintenance_config(boolean, text, text) from public;
revoke all on function public.admin_set_app_maintenance_config(boolean, text, text) from anon;
grant execute on function public.admin_set_app_maintenance_config(boolean, text, text) to authenticated;

create or replace function public.admin_create_app_announcement(
  title text,
  message text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can send app-wide notifications.'
      using errcode = '42501';
  end if;

  if nullif(trim(coalesce(title, '')), '') is null then
    raise exception 'Notification title is required.';
  end if;

  if nullif(trim(coalesce(message, '')), '') is null then
    raise exception 'Notification message is required.';
  end if;

  inserted_id := public.create_app_announcement(
    trim(title),
    trim(message),
    null,
    timezone('utc', now()),
    null
  );

  return inserted_id;
end;
$$;

revoke all on function public.admin_create_app_announcement(text, text) from public;
revoke all on function public.admin_create_app_announcement(text, text) from anon;
grant execute on function public.admin_create_app_announcement(text, text) to authenticated;
