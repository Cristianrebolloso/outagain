-- Supabase added storage.protect_delete(), a trigger that rejects any direct
-- DELETE on storage.objects — including from SECURITY DEFINER functions. That
-- broke every delete RPC that tried to clean up post/comment media inline:
-- delete_own_post, admin_delete_post, admin_delete_comment, and
-- admin_delete_user_content all bail before the actual posts/comments row
-- delete, so the app rolls back the optimistic UI removal and the post
-- reappears.
--
-- This migration recreates those four functions with the storage.objects
-- delete removed. Storage cleanup is now the client's responsibility via the
-- Storage API (which is what protect_delete tells callers to use). The Swift
-- client already cleans up the post image after delete_own_post; the admin
-- paths get the same treatment in code.

create or replace function public.delete_own_post(target_post_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_post_id alias for $1;
  post_author_id uuid;
  target_comment_ids uuid[] := array[]::uuid[];
begin
  select p.author_id
  into post_author_id
  from public.posts p
  where p.id = requested_post_id;

  if post_author_id is null then
    return;
  end if;

  if post_author_id <> auth.uid() and not public.is_app_admin(auth.uid()) then
    raise exception 'Only the post author can delete this post.' using errcode = '42501';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[])
  into target_comment_ids
  from public.comments c
  where c.post_id = requested_post_id;

  delete from public.notifications n
  where n.post_id = requested_post_id
     or n.comment_id = any(target_comment_ids);

  delete from public.comment_likes cl
  where cl.comment_id = any(target_comment_ids);

  delete from public.reactions r
  where r.post_id = requested_post_id;

  delete from public.comments c
  where c.id = any(target_comment_ids);

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Post deleted by author'
  where r.target_post_id = requested_post_id
    and r.status = 'open';

  delete from public.posts p
  where p.id = requested_post_id;
end;
$$;

revoke all on function public.delete_own_post(uuid) from public;
revoke all on function public.delete_own_post(uuid) from anon;
grant execute on function public.delete_own_post(uuid) to authenticated;

create or replace function public.admin_delete_post(target_post_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_post_id alias for $1;
  requested_report_id alias for $2;
  existing_post_id uuid;
  target_comment_ids uuid[] := array[]::uuid[];
  deleted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete reported posts.' using errcode = '42501';
  end if;

  select p.id
  into existing_post_id
  from public.posts p
  where p.id = requested_post_id;

  if existing_post_id is null then
    raise exception 'No post found for moderation delete.';
  end if;

  select coalesce(array_agg(c.id), array[]::uuid[])
  into target_comment_ids
  from public.comments c
  where c.post_id = requested_post_id;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Post deleted by @admin'
  where (requested_report_id is not null and r.id = requested_report_id)
     or (r.target_post_id = requested_post_id and r.status = 'open');

  delete from public.notifications n
  where n.post_id = requested_post_id
     or n.comment_id = any(target_comment_ids);

  delete from public.comment_likes cl
  where cl.comment_id = any(target_comment_ids);

  delete from public.reactions r
  where r.post_id = requested_post_id;

  delete from public.comments c
  where c.id = any(target_comment_ids);

  delete from public.posts p
  where p.id = requested_post_id
  returning p.id into deleted_id;

  if deleted_id is null then
    raise exception 'No post found for moderation delete.';
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
declare
  requested_comment_id alias for $1;
  requested_report_id alias for $2;
  deleted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete reported comments.' using errcode = '42501';
  end if;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Comment deleted by @admin'
  where (requested_report_id is not null and r.id = requested_report_id)
     or (r.target_comment_id = requested_comment_id and r.status = 'open');

  delete from public.comments c
  where c.id = requested_comment_id
  returning c.id into deleted_id;

  if deleted_id is null then
    raise exception 'No comment found for moderation delete.';
  end if;
end;
$$;

revoke all on function public.admin_delete_comment(uuid, uuid) from public;
revoke all on function public.admin_delete_comment(uuid, uuid) from anon;
grant execute on function public.admin_delete_comment(uuid, uuid) to authenticated;

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

  -- Storage cleanup is the client's responsibility (Supabase blocks direct
  -- deletes on storage.objects). Always report zero from the RPC.
  storage_objects_deleted := 0;

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
