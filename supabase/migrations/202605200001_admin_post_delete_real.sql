-- Make @admin post deletion a full moderation delete instead of a bare row delete.
-- This keeps reports marked as actioned, removes dependent activity rows, and
-- cleans the post/comment media objects from Supabase Storage.

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
  target_comment_ids uuid[] := '{}';
  target_media_paths text[] := '{}';
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

  select coalesce(array_agg(c.id), '{}'::uuid[])
  into target_comment_ids
  from public.comments c
  where c.post_id = requested_post_id;

  select coalesce(array_agg(path), '{}'::text[])
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

revoke all on function public.admin_delete_post(uuid, uuid) from public;
revoke all on function public.admin_delete_post(uuid, uuid) from anon;
grant execute on function public.admin_delete_post(uuid, uuid) to authenticated;
