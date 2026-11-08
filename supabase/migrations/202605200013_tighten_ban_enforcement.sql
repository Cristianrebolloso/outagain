-- Tighten ban enforcement so banned users cannot reset their identity by
-- deleting the auth user, re-signing up with the same email, or uploading
-- directly to Supabase Storage.

create extension if not exists pgcrypto;

alter table if exists public.banned_users
  add column if not exists email_hash text;

drop index if exists banned_users_email_hash_unique_idx;

create index if not exists banned_users_email_hash_idx
  on public.banned_users (email_hash)
  where email_hash is not null;

create or replace function public.normalized_email_sha256(raw_email text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when nullif(btrim(raw_email), '') is null then null
    else encode(digest(lower(btrim(raw_email)), 'sha256'), 'hex')
  end;
$$;

revoke all on function public.normalized_email_sha256(text) from public;
grant execute on function public.normalized_email_sha256(text) to authenticated;
grant execute on function public.normalized_email_sha256(text) to service_role;

create or replace function public.auth_user_email_hash(user_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select public.normalized_email_sha256(u.email)
  from auth.users u
  where u.id = user_id;
$$;

revoke all on function public.auth_user_email_hash(uuid) from public;

create or replace function public.fill_banned_user_email_hash()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email_hash is null then
    new.email_hash := public.auth_user_email_hash(new.user_id);
  end if;

  return new;
end;
$$;

drop trigger if exists banned_users_fill_email_hash on public.banned_users;
create trigger banned_users_fill_email_hash
before insert or update on public.banned_users
for each row
execute procedure public.fill_banned_user_email_hash();

update public.banned_users b
set email_hash = public.auth_user_email_hash(b.user_id)
where b.email_hash is null;

insert into public.banned_users (user_id, banned_by, reason, banned_at, email_hash)
select
  p.id,
  p.banned_by,
  coalesce(nullif(trim(p.ban_reason), ''), 'admin_action'),
  coalesce(p.banned_at, timezone('utc', now())),
  public.auth_user_email_hash(p.id)
from public.profiles p
where coalesce(p.is_banned, false)
on conflict (user_id) do update
set
  banned_by = excluded.banned_by,
  reason = excluded.reason,
  banned_at = excluded.banned_at,
  email_hash = coalesce(excluded.email_hash, public.banned_users.email_hash);

create or replace function public.sync_profile_ban_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.is_banned, false) then
    insert into public.banned_users (user_id, banned_by, reason, banned_at, email_hash)
    values (
      new.id,
      new.banned_by,
      coalesce(nullif(trim(new.ban_reason), ''), 'admin_action'),
      coalesce(new.banned_at, timezone('utc', now())),
      public.auth_user_email_hash(new.id)
    )
    on conflict (user_id) do update
    set
      banned_by = excluded.banned_by,
      reason = excluded.reason,
      banned_at = excluded.banned_at,
      email_hash = coalesce(excluded.email_hash, public.banned_users.email_hash);
  else
    delete from public.banned_users
    where user_id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_sync_ban_identity on public.profiles;
drop trigger if exists profiles_sync_ban_identity_insert on public.profiles;
drop trigger if exists profiles_sync_ban_identity_update on public.profiles;

create trigger profiles_sync_ban_identity_insert
after insert on public.profiles
for each row
execute procedure public.sync_profile_ban_identity();

create trigger profiles_sync_ban_identity_update
after update of is_banned, banned_at, banned_by, ban_reason on public.profiles
for each row
execute procedure public.sync_profile_ban_identity();

create or replace function public.is_profile_banned(user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((
      select p.is_banned
      from public.profiles p
      where p.id = user_id
    ), false)
    or exists (
      select 1
      from public.banned_users b
      where b.user_id = user_id
    )
    or exists (
      select 1
      from auth.users u
      join public.banned_users b
        on b.email_hash = public.normalized_email_sha256(u.email)
      where u.id = user_id
        and b.email_hash is not null
    );
$$;

revoke all on function public.is_profile_banned(uuid) from public;
revoke all on function public.is_profile_banned(uuid) from anon;
grant execute on function public.is_profile_banned(uuid) to authenticated;

create or replace function public.reject_banned_auth_signup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate_email_hash text;
begin
  candidate_email_hash := public.normalized_email_sha256(new.email);

  if candidate_email_hash is not null and exists (
    select 1
    from public.banned_users b
    where b.email_hash = candidate_email_hash
  ) then
    raise exception 'This account has been banned from Out Again.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists auth_users_reject_banned_email on auth.users;
create trigger auth_users_reject_banned_email
before insert on auth.users
for each row
execute procedure public.reject_banned_auth_signup();

create or replace function public.reject_banned_user_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_profile_banned(auth.uid()) and not public.is_app_admin(auth.uid()) then
    raise exception 'This account has been banned from Out Again.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop policy if exists "users can upload own avatars" on storage.objects;
create policy "users can upload own avatars"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = 'users'
  and (storage.foldername(name))[2] = auth.uid()::text
  and not public.is_profile_banned(auth.uid())
);

drop policy if exists "users can upload own moments" on storage.objects;
create policy "users can upload own moments"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'posts'
  and (storage.foldername(name))[2] = auth.uid()::text
  and not public.is_profile_banned(auth.uid())
);

drop policy if exists "users can upload own comment photos" on storage.objects;
create policy "users can upload own comment photos"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'comments'
  and (storage.foldername(name))[2] = auth.uid()::text
  and not public.is_profile_banned(auth.uid())
);
