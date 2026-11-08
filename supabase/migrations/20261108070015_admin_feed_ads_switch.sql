-- Only public application settings belong in client configuration responses.
-- Legacy server credentials remain available to server roles, never app clients.
drop policy if exists "app config readable by everyone" on public.app_config;
create policy "app config readable by everyone" on public.app_config
for select to anon, authenticated
using (key in ('maintenance_mode_enabled', 'maintenance_enabled', 'app_unavailable',
 'maintenance_title', 'maintenance_message', 'passkeys_enabled', 'feed_ads_enabled')
 or key like 'curated_follower_count:%');

insert into public.app_config (key, value) values ('feed_ads_enabled', 'false')
on conflict on constraint app_config_pkey do nothing;

-- A narrow RLS-authorized update, without a privileged public RPC.
grant update (value) on public.app_config to authenticated;
create policy "admin can update feed ads switch" on public.app_config
for update to authenticated
using (key = 'feed_ads_enabled' and auth.uid() is not null and public.is_app_admin(auth.uid()))
with check (key = 'feed_ads_enabled' and auth.uid() is not null and public.is_app_admin(auth.uid()));

create or replace function public.admin_set_feed_ads(enabled boolean)
returns table (key text, value text)
language plpgsql security invoker set search_path = ''
as $$
begin
  if auth.uid() is null or not coalesce(public.is_app_admin(auth.uid()), false) then
    raise exception 'Only @admin can manage feed ads.' using errcode = '42501';
  end if;
  return query
  update public.app_config c
  set value = case when coalesce(enabled, false) then 'true' else 'false' end
  where c.key = 'feed_ads_enabled'
  returning c.key, c.value;
end;
$$;
revoke all on function public.admin_set_feed_ads(boolean) from public, anon;
grant execute on function public.admin_set_feed_ads(boolean) to authenticated;
