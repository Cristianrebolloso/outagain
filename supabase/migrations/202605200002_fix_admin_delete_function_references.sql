-- Remove ambiguous moderation function references and keep admin deletes
-- deterministic when report ids are supplied by the app.

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
  target_media_paths text[] := array[]::text[];
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

  select coalesce(array_agg(path), array[]::text[])
  into target_media_paths
  from (
    select p.image_path as path
    from public.posts p
    where p.id = requested_post_id
      and p.image_path is not null

    union

    select c.image_path as path
    from public.comments c
    where c.post_id = requested_post_id
      and c.image_path is not null
  ) media;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Post deleted by @admin'
  where (requested_report_id is not null and r.id = requested_report_id)
     or (r.target_post_id = requested_post_id and r.status = 'open');

  delete from storage.objects so
  where so.bucket_id = 'moments'
    and so.name = any(target_media_paths);

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

create or replace function public.admin_delete_comment(target_comment_id uuid, report_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_comment_id alias for $1;
  requested_report_id alias for $2;
  comment_media_path text;
  deleted_id uuid;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete reported comments.' using errcode = '42501';
  end if;

  select c.image_path
  into comment_media_path
  from public.comments c
  where c.id = requested_comment_id;

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Comment deleted by @admin'
  where (requested_report_id is not null and r.id = requested_report_id)
     or (r.target_comment_id = requested_comment_id and r.status = 'open');

  delete from storage.objects so
  where so.bucket_id = 'moments'
    and so.name = comment_media_path
    and comment_media_path is not null;

  delete from public.comments c
  where c.id = requested_comment_id
  returning c.id into deleted_id;

  if deleted_id is null then
    raise exception 'No comment found for moderation delete.';
  end if;
end;
$$;

revoke all on function public.admin_delete_post(uuid, uuid) from public;
revoke all on function public.admin_delete_post(uuid, uuid) from anon;
grant execute on function public.admin_delete_post(uuid, uuid) to authenticated;

revoke all on function public.admin_delete_comment(uuid, uuid) from public;
revoke all on function public.admin_delete_comment(uuid, uuid) from anon;
grant execute on function public.admin_delete_comment(uuid, uuid) to authenticated;
