-- Make normal user post deletion perform the same cleanup guarantees as
-- moderation deletion: related notifications, reactions, comments, comment
-- likes, and storage objects are removed in one server-side transaction.

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
  target_media_paths text[] := array[]::text[];
  deleted_id uuid;
begin
  select p.author_id
  into post_author_id
  from public.posts p
  where p.id = requested_post_id;

  -- Idempotent delete: if another device already removed the row, the desired
  -- end state is already true.
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

  update public.content_reports r
  set status = 'actioned',
      reviewed_at = timezone('utc', now()),
      moderator_note = 'Post deleted by author'
  where r.target_post_id = requested_post_id
    and r.status = 'open';

  delete from public.posts p
  where p.id = requested_post_id
  returning p.id into deleted_id;
end;
$$;

revoke all on function public.delete_own_post(uuid) from public;
revoke all on function public.delete_own_post(uuid) from anon;
grant execute on function public.delete_own_post(uuid) to authenticated;
