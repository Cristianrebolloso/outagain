-- Server-controlled app configuration and maintenance mode.
--
-- The iOS app reads this table anonymously at launch, foreground, and once per
-- foreground polling minute. Keep writes in the Supabase dashboard / SQL
-- editor so the app can be taken down or brought back without shipping a new
-- binary.

create table if not exists public.app_config (
  key text primary key,
  value text not null default '',
  updated_at timestamptz not null default timezone('utc', now())
);

create or replace function public.touch_app_config_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists app_config_touch_updated_at on public.app_config;
create trigger app_config_touch_updated_at
before update on public.app_config
for each row
execute function public.touch_app_config_updated_at();

alter table public.app_config enable row level security;

drop policy if exists "app config readable by everyone" on public.app_config;
create policy "app config readable by everyone"
on public.app_config
for select
to anon, authenticated
using (true);

revoke all on public.app_config from anon, authenticated;
grant select on public.app_config to anon, authenticated;

insert into public.app_config (key, value)
values
  ('maintenance_mode_enabled', 'false'),
  ('maintenance_title', 'Out Again is currently unavailable'),
  ('maintenance_message', 'We''re doing some work behind the scenes. Please check back soon.')
on conflict (key) do nothing;
