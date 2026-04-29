alter table if exists public.profiles
  add column if not exists custom_drinks jsonb not null default '[]'::jsonb,
  add column if not exists deleted_drink_names text[] not null default '{}'::text[],
  add column if not exists drink_order_names text[] not null default '{}'::text[];
