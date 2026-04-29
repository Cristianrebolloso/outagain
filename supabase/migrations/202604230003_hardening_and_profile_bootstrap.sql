-- Hardening pass #1:
--   (a) comments.id now defaults to gen_random_uuid(), aligning with every
--       other table in the schema. The client still supplies its own UUID for
--       optimistic UI continuity; this default is defense in depth for any
--       code path (server-side, webhook, test fixture) that omits the column.
--   (b) profiles gains avatar_version for CDN cache-busting after PFP changes.
--   (c) reserved_usernames table + trigger enforces the reserved list on the
--       server so a client bypass cannot claim 'admin', 'support', etc.
--   (d) on_auth_user_created trigger creates a shell profile row when a user
--       finishes Sign in with Apple, preventing orphan auth accounts if the
--       client crashes between auth and profile creation.
--   (e) display_name and username made nullable-friendly so the shell row is
--       valid; finishProfile() on the client upserts the real values.

-- (a) comments.id default ----------------------------------------------------

alter table public.comments
  alter column id set default gen_random_uuid();

-- (b) profiles.avatar_version ------------------------------------------------

alter table public.profiles
  add column if not exists avatar_version integer not null default 1;

create or replace function public.bump_avatar_version()
returns trigger
language plpgsql
as $$
begin
  if new.avatar_path is distinct from old.avatar_path then
    new.avatar_version = coalesce(old.avatar_version, 0) + 1;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_bump_avatar_version on public.profiles;
create trigger profiles_bump_avatar_version
before update on public.profiles
for each row
execute procedure public.bump_avatar_version();

-- (c) reserved_usernames -----------------------------------------------------

create table if not exists public.reserved_usernames (
  username text primary key check (username = lower(username)),
  reason text,
  created_at timestamptz not null default timezone('utc', now())
);

insert into public.reserved_usernames (username, reason) values
  ('admin', 'system'),
  ('support', 'system'),
  ('help', 'system'),
  ('moderator', 'system'),
  ('outagain', 'brand'),
  ('out_again', 'brand'),
  ('team', 'brand'),
  ('staff', 'brand'),
  ('owner', 'system'),
  ('root', 'system'),
  ('api', 'system'),
  ('null', 'system'),
  ('undefined', 'system')
on conflict (username) do nothing;

alter table public.reserved_usernames enable row level security;

-- Readable so the client can show "not available" hints; writes are
-- restricted to service_role (implicit — no policy granting write).
drop policy if exists "reserved usernames are readable" on public.reserved_usernames;
create policy "reserved usernames are readable"
on public.reserved_usernames
for select
to authenticated, anon
using (true);

create or replace function public.enforce_reserved_username()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.username is null then
    return new;
  end if;

  if exists (
    select 1
    from public.reserved_usernames r
    where r.username = lower(new.username)
  ) then
    raise exception 'Username "%" is reserved.', new.username
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_enforce_reserved_username on public.profiles;
create trigger profiles_enforce_reserved_username
before insert or update of username on public.profiles
for each row
execute procedure public.enforce_reserved_username();

-- (d) on_auth_user_created ---------------------------------------------------
-- Relax the NOT NULL on display_name/username so the shell row inserted by
-- the trigger is valid. The app treats any profile with an empty username as
-- "needs onboarding" and routes the user back to the onboarding flow. A CHECK
-- constraint still enforces the format when a username IS set.

alter table public.profiles
  alter column display_name drop not null;

alter table public.profiles
  alter column username drop not null;

alter table public.profiles
  drop constraint if exists profiles_username_check;

alter table public.profiles
  add constraint profiles_username_check
  check (username is null or username ~ '^[a-z0-9_]{3,20}$');

-- Ensure the unique constraint still applies but tolerates multiple shell
-- rows in a weird recovery scenario (it won't happen in practice, because
-- profiles.id is a PK referencing auth.users; there is only ever one row per
-- user, with or without a username).

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username, display_name, apple_user_identifier)
  values (
    new.id,
    null,
    null,
    nullif(new.raw_user_meta_data->>'sub', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute procedure public.handle_new_auth_user();
