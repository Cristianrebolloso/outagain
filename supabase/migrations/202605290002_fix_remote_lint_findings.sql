-- Fix remote lint findings in announcement/admin RPCs.

create or replace function public.mark_app_announcement_seen(announcement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  viewer_id uuid := auth.uid();
begin
  if viewer_id is null then
    raise exception 'Not authenticated.';
  end if;

  insert into public.app_announcement_receipts (announcement_id, user_id, seen_at)
  select a.id, viewer_id, now()
  from public.app_announcements a
  where a.id = $1
    and (
      a.target_user_ids is null
      or cardinality(a.target_user_ids) = 0
      or viewer_id = any(a.target_user_ids)
    )
  on conflict (announcement_id, user_id)
  do update set seen_at = excluded.seen_at;
end;
$$;

revoke all on function public.mark_app_announcement_seen(uuid) from public;
revoke all on function public.mark_app_announcement_seen(uuid) from anon;
grant execute on function public.mark_app_announcement_seen(uuid) to authenticated;

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
  target_post_ids uuid[] := array[]::uuid[];
  target_comment_ids uuid[] := array[]::uuid[];
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only @admin can delete user content.'
      using errcode = '42501';
  end if;

  if public.is_app_admin(target_user_id) then
    raise exception 'The @admin account cannot be purged.'
      using errcode = '42501';
  end if;

  select coalesce(array_agg(p.id), array[]::uuid[])
  into target_post_ids
  from public.posts p
  where p.author_id = target_user_id;

  select coalesce(array_agg(c.id), array[]::uuid[])
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
