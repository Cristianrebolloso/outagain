-- Admin moderation controls.
--
-- The @admin account can:
--   * ban or unban user profiles;
--   * purge a user's app content while leaving the profile available to unban;
--   * resolve reports and delete individual posts.
--
-- Banned accounts can still authenticate with Supabase, but the app detects
-- profiles.is_banned on bootstrap and signs them out with a clear message.
-- Server-side triggers also block banned accounts from writing app data.

alter table public.profiles
  add column if not exists is_banned boolean not null default false,
  add column if not exists banned_at timestamptz,
  add column if not exists banned_by uuid references public.profiles(id) on delete set null,
  add column if not exists ban_reason text;

create or replace function public.is_app_admin(user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = user_id
      and lower(coalesce(p.username, '')) = 'admin'
      and coalesce(p.is_banned, false) = false
  );
$$;

revoke all on function public.is_app_admin(uuid) from public;
revoke all on function public.is_app_admin(uuid) from anon;
grant execute on function public.is_app_admin(uuid) to authenticated;

create or replace function public.is_profile_banned(user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select p.is_banned
    from public.profiles p
    where p.id = user_id
  ), false);
$$;

revoke all on function public.is_profile_banned(uuid) from public;
revoke all on function public.is_profile_banned(uuid) from anon;
grant execute on function public.is_profile_banned(uuid) to authenticated;

create or replace function public.protect_profile_moderation_fields()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), current_user) in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.is_banned = false;
    new.banned_at = null;
    new.banned_by = null;
    new.ban_reason = null;
    return new;
  end if;

  if new.is_banned is distinct from old.is_banned
     or new.banned_at is distinct from old.banned_at
     or new.banned_by is distinct from old.banned_by
     or new.ban_reason is distinct from old.ban_reason
  then
    raise exception 'Only @admin can change moderation status.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_moderation_fields on public.profiles;
create trigger profiles_protect_moderation_fields
before insert or update of is_banned, banned_at, banned_by, ban_reason on public.profiles
for each row
execute procedure public.protect_profile_moderation_fields();

create or replace function public.reject_banned_user_write()
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

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_reject_banned_write on public.profiles;
create trigger profiles_reject_banned_write
before update on public.profiles
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists posts_reject_banned_write on public.posts;
create trigger posts_reject_banned_write
before insert or update or delete on public.posts
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists comments_reject_banned_write on public.comments;
create trigger comments_reject_banned_write
before insert or update or delete on public.comments
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists reactions_reject_banned_write on public.reactions;
create trigger reactions_reject_banned_write
before insert or delete on public.reactions
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists notifications_reject_banned_write on public.notifications;
create trigger notifications_reject_banned_write
before update or delete on public.notifications
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists friendships_reject_banned_write on public.friendships;
create trigger friendships_reject_banned_write
before insert or update or delete on public.friendships
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists devices_reject_banned_write on public.devices;
create trigger devices_reject_banned_write
before insert or update or delete on public.devices
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists content_reports_reject_banned_write on public.content_reports;
create trigger content_reports_reject_banned_write
before insert on public.content_reports
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists comment_likes_reject_banned_write on public.comment_likes;
create trigger comment_likes_reject_banned_write
before insert or delete on public.comment_likes
for each row
execute procedure public.reject_banned_user_write();

drop trigger if exists night_groups_reject_banned_write on public.night_groups;
create trigger night_groups_reject_banned_write
before insert or update or delete on public.night_groups
for each row
execute procedure public.reject_banned_user_write();

create or replace function public.admin_profiles(
  limit_count integer default 20,
  offset_count integer default 0
)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  is_verified boolean,
  is_banned boolean,
  custom_drinks jsonb,
  deleted_drink_names text[],
  drink_order_names text[]
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can manage users.'
      using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.is_verified, false) as is_verified,
    coalesce(p.is_banned, false) as is_banned,
    to_jsonb(p.custom_drinks) as custom_drinks,
    p.deleted_drink_names,
    p.drink_order_names
  from public.profiles p
  where p.username is not null
  order by coalesce(p.display_name, p.username) asc, p.id asc
  limit least(greatest(coalesce(limit_count, 20), 1), 100)
  offset greatest(coalesce(offset_count, 0), 0);
end;
$$;

revoke all on function public.admin_profiles(integer, integer) from public;
revoke all on function public.admin_profiles(integer, integer) from anon;
grant execute on function public.admin_profiles(integer, integer) to authenticated;

create or replace function public.admin_set_profile_verified(
  target_user_id uuid,
  verified boolean
)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  is_verified boolean,
  is_banned boolean,
  custom_drinks jsonb,
  deleted_drink_names text[],
  drink_order_names text[]
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can verify users.'
      using errcode = '42501';
  end if;

  return query
  update public.profiles p
  set is_verified = coalesce(verified, false)
  where p.id = target_user_id
  returning
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    p.is_verified,
    coalesce(p.is_banned, false) as is_banned,
    to_jsonb(p.custom_drinks) as custom_drinks,
    p.deleted_drink_names,
    p.drink_order_names;

  if not found then
    raise exception 'No profile found for that user.'
      using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_set_profile_verified(uuid, boolean) from public;
revoke all on function public.admin_set_profile_verified(uuid, boolean) from anon;
grant execute on function public.admin_set_profile_verified(uuid, boolean) to authenticated;

create or replace function public.admin_set_user_banned(
  target_user_id uuid,
  banned boolean,
  reason text default null
)
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer,
  is_verified boolean,
  is_banned boolean,
  custom_drinks jsonb,
  deleted_drink_names text[],
  drink_order_names text[]
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can ban users.'
      using errcode = '42501';
  end if;

  if public.is_app_admin(target_user_id) then
    raise exception 'The @admin account cannot be banned.'
      using errcode = '42501';
  end if;

  return query
  update public.profiles p
  set
    is_banned = coalesce(banned, false),
    banned_at = case when coalesce(banned, false) then timezone('utc', now()) else null end,
    banned_by = case when coalesce(banned, false) then auth.uid() else null end,
    ban_reason = case when coalesce(banned, false) then nullif(trim(reason), '') else null end
  where p.id = target_user_id
  returning
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version,
    coalesce(p.is_verified, false) as is_verified,
    p.is_banned,
    to_jsonb(p.custom_drinks) as custom_drinks,
    p.deleted_drink_names,
    p.drink_order_names;

  if not found then
    raise exception 'No profile found for that user.'
      using errcode = 'P0002';
  end if;

  if coalesce(banned, false) then
    delete from public.devices
    where user_id = target_user_id;
  end if;
end;
$$;

revoke all on function public.admin_set_user_banned(uuid, boolean, text) from public;
revoke all on function public.admin_set_user_banned(uuid, boolean, text) from anon;
grant execute on function public.admin_set_user_banned(uuid, boolean, text) to authenticated;

create or replace function public.admin_delete_user_content(target_user_id uuid)
returns table (
  posts_deleted integer,
  comments_deleted integer,
  reactions_deleted integer,
  comment_likes_deleted integer,
  friendships_deleted integer,
  notifications_deleted integer,
  content_reports_deleted integer,
  groups_deleted integer,
  groups_updated integer,
  devices_deleted integer,
  storage_objects_deleted integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_post_ids uuid[] := '{}';
  target_comment_ids uuid[] := '{}';
  target_media_paths text[] := '{}';
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete user content.'
      using errcode = '42501';
  end if;

  if public.is_app_admin(target_user_id) then
    raise exception 'The @admin account cannot be purged.'
      using errcode = '42501';
  end if;

  select coalesce(array_agg(p.id), '{}'::uuid[])
  into target_post_ids
  from public.posts p
  where p.author_id = target_user_id;

  select coalesce(array_agg(c.id), '{}'::uuid[])
  into target_comment_ids
  from public.comments c
  where c.author_id = target_user_id
     or c.post_id = any(target_post_ids);

  select coalesce(array_agg(path), '{}'::text[])
  into target_media_paths
  from (
    select p.image_path as path
    from public.posts p
    where p.id = any(target_post_ids)
      and p.image_path is not null

    union

    select c.image_path as path
    from public.comments c
    where c.id = any(target_comment_ids)
      and c.image_path is not null
  ) media;

  delete from storage.objects so
  where so.bucket_id = 'moments'
    and so.name = any(target_media_paths);
  get diagnostics storage_objects_deleted = row_count;

  delete from public.content_reports cr
  where cr.reporter_id = target_user_id
     or cr.target_author_id = target_user_id
     or cr.target_post_id = any(target_post_ids)
     or cr.target_comment_id = any(target_comment_ids);
  get diagnostics content_reports_deleted = row_count;

  delete from public.notifications n
  where n.user_id = target_user_id
     or n.actor_id = target_user_id
     or n.post_id = any(target_post_ids)
     or n.comment_id = any(target_comment_ids);
  get diagnostics notifications_deleted = row_count;

  delete from public.comment_likes cl
  where cl.user_id = target_user_id
     or cl.comment_id = any(target_comment_ids);
  get diagnostics comment_likes_deleted = row_count;

  delete from public.reactions r
  where r.user_id = target_user_id
     or r.post_id = any(target_post_ids);
  get diagnostics reactions_deleted = row_count;

  delete from public.comments c
  where c.id = any(target_comment_ids);
  get diagnostics comments_deleted = row_count;

  delete from public.posts p
  where p.id = any(target_post_ids);
  get diagnostics posts_deleted = row_count;

  delete from public.friendships f
  where f.user_id = target_user_id
     or f.friend_id = target_user_id;
  get diagnostics friendships_deleted = row_count;

  delete from public.night_groups ng
  where ng.creator_id = target_user_id;
  get diagnostics groups_deleted = row_count;

  update public.night_groups ng
  set member_ids = array_remove(ng.member_ids, target_user_id)
  where target_user_id = any(ng.member_ids);
  get diagnostics groups_updated = row_count;

  delete from public.devices d
  where d.user_id = target_user_id;
  get diagnostics devices_deleted = row_count;

  return next;
end;
$$;

revoke all on function public.admin_delete_user_content(uuid) from public;
revoke all on function public.admin_delete_user_content(uuid) from anon;
grant execute on function public.admin_delete_user_content(uuid) to authenticated;

create or replace function public.admin_delete_post(target_post_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete posts.'
      using errcode = '42501';
  end if;

  delete from public.posts p
  where p.id = target_post_id;

  if report_id is not null then
    update public.content_reports cr
    set
      status = 'actioned',
      reviewed_at = timezone('utc', now())
    where cr.id = report_id;
  end if;
end;
$$;

revoke all on function public.admin_delete_post(uuid, uuid) from public;
revoke all on function public.admin_delete_post(uuid, uuid) from anon;
grant execute on function public.admin_delete_post(uuid, uuid) to authenticated;

create or replace function public.admin_delete_comment(target_comment_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete comments.'
      using errcode = '42501';
  end if;

  delete from public.comments c
  where c.id = target_comment_id;

  if report_id is not null then
    update public.content_reports cr
    set
      status = 'actioned',
      reviewed_at = timezone('utc', now())
    where cr.id = report_id;
  end if;
end;
$$;

revoke all on function public.admin_delete_comment(uuid, uuid) from public;
revoke all on function public.admin_delete_comment(uuid, uuid) from anon;
grant execute on function public.admin_delete_comment(uuid, uuid) to authenticated;

create or replace function public.admin_content_reports(
  limit_count integer default 50,
  offset_count integer default 0
)
returns table (
  id uuid,
  created_at timestamptz,
  reporter_id uuid,
  reporter_username text,
  target_type text,
  target_post_id uuid,
  target_comment_id uuid,
  target_author_id uuid,
  target_author_username text,
  target_excerpt text,
  reason text,
  detail text,
  status text,
  reviewed_at timestamptz,
  moderator_note text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can read reports.'
      using errcode = '42501';
  end if;

  return query
  select
    cr.id,
    cr.created_at,
    cr.reporter_id,
    cr.reporter_username,
    cr.target_type,
    cr.target_post_id,
    cr.target_comment_id,
    cr.target_author_id,
    cr.target_author_username,
    cr.target_excerpt,
    cr.reason,
    cr.detail,
    cr.status,
    cr.reviewed_at,
    cr.moderator_note
  from public.content_reports cr
  order by cr.created_at desc
  limit least(greatest(coalesce(limit_count, 50), 1), 100)
  offset greatest(coalesce(offset_count, 0), 0);
end;
$$;

revoke all on function public.admin_content_reports(integer, integer) from public;
revoke all on function public.admin_content_reports(integer, integer) from anon;
grant execute on function public.admin_content_reports(integer, integer) to authenticated;

create or replace function public.admin_resolve_content_report(report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can resolve reports.'
      using errcode = '42501';
  end if;

  update public.content_reports cr
  set
    status = 'reviewed',
    reviewed_at = timezone('utc', now())
  where cr.id = report_id;
end;
$$;

revoke all on function public.admin_resolve_content_report(uuid) from public;
revoke all on function public.admin_resolve_content_report(uuid) from anon;
grant execute on function public.admin_resolve_content_report(uuid) to authenticated;
