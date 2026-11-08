-- Some remote app_config tables were created before the maintenance migration
-- added updated_at. The touch trigger expects this column on every update.

alter table public.app_config
  add column if not exists updated_at timestamptz;

update public.app_config
set updated_at = timezone('utc', now())
where updated_at is null;

alter table public.app_config
  alter column updated_at set default timezone('utc', now()),
  alter column updated_at set not null;

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
