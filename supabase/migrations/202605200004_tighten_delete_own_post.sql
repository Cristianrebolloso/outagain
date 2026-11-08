-- Remove the unused deleted_id variable from delete_own_post so database lint
-- stays clean for the post-delete cleanup function.

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
  where p.id = requested_post_id;
end;
$$;

revoke all on function public.delete_own_post(uuid) from public;
revoke all on function public.delete_own_post(uuid) from anon;
grant execute on function public.delete_own_post(uuid) to authenticated;
