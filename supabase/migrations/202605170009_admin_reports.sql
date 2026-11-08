-- In-app moderation for the @admin account.
--
-- Reports stay in content_reports. Authenticated clients cannot moderate
-- directly through table RLS; @admin uses SECURITY DEFINER RPCs below.

-- 202605170002_admin_moderation_controls creates the canonical
-- is_app_admin(uuid default auth.uid()) helper. Drop any legacy zero-argument
-- overload so calls are not ambiguous when the uuid helper has a default arg.
drop function if exists public.is_app_admin();

-- Let user-profile reports land in the same queue as post/comment reports.
alter table public.content_reports
  drop constraint if exists content_reports_target_type_check;

alter table public.content_reports
  add constraint content_reports_target_type_check
  check (target_type in ('post', 'comment', 'user'));

alter table public.content_reports
  drop constraint if exists content_reports_target_shape;

alter table public.content_reports
  add constraint content_reports_target_shape check (
    (target_type = 'post' and target_post_id is not null and target_comment_id is null)
    or
    (target_type = 'comment' and target_post_id is not null and target_comment_id is not null)
    or
    (target_type = 'user' and target_post_id is null and target_comment_id is null)
  );

create unique index if not exists content_reports_reporter_user_unique_idx
  on public.content_reports (reporter_id, target_author_id)
  where target_type = 'user';

create table if not exists public.banned_users (
  user_id uuid primary key,
  banned_by uuid,
  reason text not null default '',
  banned_at timestamptz not null default timezone('utc', now())
);

alter table public.banned_users enable row level security;

drop policy if exists "admins can read banned users" on public.banned_users;
create policy "admins can read banned users"
on public.banned_users
for select
to authenticated
using (public.is_app_admin(auth.uid()));

create or replace function public.reject_banned_user_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.banned_users b
    where b.user_id = auth.uid()
  ) then
    raise exception 'This account has been banned.';
  end if;

  return new;
end;
$$;

drop trigger if exists posts_reject_banned_user on public.posts;
create trigger posts_reject_banned_user
before insert or update on public.posts
for each row execute procedure public.reject_banned_user_activity();

drop trigger if exists comments_reject_banned_user on public.comments;
create trigger comments_reject_banned_user
before insert or update on public.comments
for each row execute procedure public.reject_banned_user_activity();

drop trigger if exists reactions_reject_banned_user on public.reactions;
create trigger reactions_reject_banned_user
before insert or update on public.reactions
for each row execute procedure public.reject_banned_user_activity();

drop trigger if exists comment_likes_reject_banned_user on public.comment_likes;
create trigger comment_likes_reject_banned_user
before insert or update on public.comment_likes
for each row execute procedure public.reject_banned_user_activity();

drop trigger if exists friendships_reject_banned_user on public.friendships;
create trigger friendships_reject_banned_user
before insert or update on public.friendships
for each row execute procedure public.reject_banned_user_activity();

create or replace function public.admin_content_reports(
  limit_count integer default 25,
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
    raise exception 'Only @admin can review reports.' using errcode = '42501';
  end if;

  return query
  select
    r.id,
    r.created_at,
    r.reporter_id,
    r.reporter_username,
    r.target_type,
    r.target_post_id,
    r.target_comment_id,
    r.target_author_id,
    r.target_author_username,
    r.target_excerpt,
    r.reason,
    r.detail,
    r.status,
    r.reviewed_at,
    r.moderator_note
  from public.content_reports r
  order by (r.status = 'open') desc, r.created_at desc
  limit least(greatest(coalesce(limit_count, 25), 1), 100)
  offset greatest(coalesce(offset_count, 0), 0);
end;
$$;

create or replace function public.admin_resolve_report(report_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can resolve reports.' using errcode = '42501';
  end if;

  update public.content_reports r
  set status = 'reviewed',
      reviewed_at = timezone('utc', now()),
      moderator_note = coalesce(r.moderator_note, 'Reviewed in app')
  where r.id = report_id;
end;
$$;

create or replace function public.admin_delete_post(target_post_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete reported posts.' using errcode = '42501';
  end if;

  delete from public.posts p
  where p.id = target_post_id
  returning p.id into deleted_id;

  if deleted_id is null then
    raise exception 'No post found for moderation delete.';
  end if;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Post deleted by @admin'
  where (report_id is not null and r.id = report_id)
     or (report_id is null and r.target_post_id = target_post_id and r.status = 'open');
end;
$$;

create or replace function public.admin_delete_comment(target_comment_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete reported comments.' using errcode = '42501';
  end if;

  delete from public.comments c
  where c.id = target_comment_id
  returning c.id into deleted_id;

  if deleted_id is null then
    raise exception 'No comment found for moderation delete.';
  end if;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Comment deleted by @admin'
  where (report_id is not null and r.id = report_id)
     or (report_id is null and r.target_comment_id = target_comment_id and r.status = 'open');
end;
$$;

create or replace function public.admin_ban_user(target_user_id uuid, report_id uuid default null, reason text default 'admin_action')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can ban users.' using errcode = '42501';
  end if;

  if target_user_id = auth.uid() then
    raise exception 'Admin cannot ban itself.';
  end if;

  insert into public.banned_users (user_id, banned_by, reason)
  values (target_user_id, auth.uid(), coalesce(reason, 'admin_action'))
  on conflict (user_id) do update
    set banned_by = excluded.banned_by,
        reason = excluded.reason,
        banned_at = timezone('utc', now());

  delete from public.devices d
  where d.user_id = target_user_id;

  delete from public.friendships f
  where f.user_id = target_user_id
     or f.friend_id = target_user_id;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'User banned by @admin'
  where (report_id is not null and r.id = report_id)
     or (report_id is null and r.target_author_id = target_user_id and r.status = 'open');
end;
$$;

create or replace function public.set_profile_verified(profile_username text, verified boolean default true)
returns table (
  id uuid,
  username text,
  is_verified boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can change profile verification.' using errcode = '42501';
  end if;

  return query
  update public.profiles p
  set is_verified = verified
  where lower(p.username) = lower(profile_username)
  returning p.id, p.username, p.is_verified;

  if not found then
    raise exception 'No profile found for username "%".', profile_username;
  end if;
end;
$$;

revoke all on function public.admin_content_reports(integer, integer) from public;
revoke all on function public.admin_content_reports(integer, integer) from anon;
grant execute on function public.admin_content_reports(integer, integer) to authenticated;

revoke all on function public.admin_resolve_report(uuid) from public;
revoke all on function public.admin_resolve_report(uuid) from anon;
grant execute on function public.admin_resolve_report(uuid) to authenticated;

revoke all on function public.admin_delete_post(uuid, uuid) from public;
revoke all on function public.admin_delete_post(uuid, uuid) from anon;
grant execute on function public.admin_delete_post(uuid, uuid) to authenticated;

revoke all on function public.admin_delete_comment(uuid, uuid) from public;
revoke all on function public.admin_delete_comment(uuid, uuid) from anon;
grant execute on function public.admin_delete_comment(uuid, uuid) to authenticated;

revoke all on function public.admin_ban_user(uuid, uuid, text) from public;
revoke all on function public.admin_ban_user(uuid, uuid, text) from anon;
grant execute on function public.admin_ban_user(uuid, uuid, text) to authenticated;

revoke all on function public.set_profile_verified(text, boolean) from public;
revoke all on function public.set_profile_verified(text, boolean) from anon;
grant execute on function public.set_profile_verified(text, boolean) to authenticated;
grant execute on function public.set_profile_verified(text, boolean) to service_role;
