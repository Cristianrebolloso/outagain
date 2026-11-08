-- Expand comment notification coverage to include replies.
--
-- Before this migration, notify_on_comment() only notified the post author.
-- That meant direct replies inside a thread could land silently for the
-- original commenter, even though the UI already models reply targets via
-- reply_to_comment_id. This migration fans out to:
--   1. the post author (existing behavior), and
--   2. the replied-to comment author when different from both the actor and
--      the post author.

create or replace function public.notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  post_author_id uuid;
  reply_author_id uuid;
  notification_kind text;
  notification_detail text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.author_id;

  select posts.author_id
    into post_author_id
  from public.posts
  where posts.id = new.post_id;

  if new.reply_to_comment_id is not null then
    select comments.author_id
      into reply_author_id
    from public.comments
    where comments.id = new.reply_to_comment_id;
  end if;

  notification_kind := case when new.kind = 'photo' then 'photoReply' else 'comment' end;
  notification_detail := left(new.body, 160);

  if post_author_id is not null and post_author_id <> new.author_id then
    insert into public.notifications (user_id, actor_id, post_id, comment_id, kind, title, detail)
    values (
      post_author_id,
      new.author_id,
      new.post_id,
      new.id,
      notification_kind,
      coalesce(actor_name, 'Someone') || ' commented on your post',
      notification_detail
    );
  end if;

  if reply_author_id is not null
     and reply_author_id <> new.author_id
     and reply_author_id <> post_author_id then
    insert into public.notifications (user_id, actor_id, post_id, comment_id, kind, title, detail)
    values (
      reply_author_id,
      new.author_id,
      new.post_id,
      new.id,
      notification_kind,
      coalesce(actor_name, 'Someone') || ' replied to your comment',
      notification_detail
    );
  end if;

  return new;
end;
$$;
