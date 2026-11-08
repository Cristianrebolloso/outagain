-- Deduplicate like and comment-like notifications.
--
-- Problem: every like creates a new notification row unconditionally. When a
-- user likes → unlikes → likes again, the recipient receives 2+ notifications
-- for the same action. The correct behaviour is exactly 1 notification per
-- actor+target+kind, refreshed on re-like.
--
-- Fix: rewrite both notify functions to DELETE any existing notification for
-- the same (user_id, actor_id, post_id/comment_id, kind) before inserting.
-- The delete is a no-op on the first like, so normal behaviour is unchanged.
-- On re-like after an unlike, the old row is replaced with a fresh one (new
-- id, new created_at) so the notification surfaces at the top of the feed.
--
-- The Swift client's deleteReactionNotification / deleteCommentLikeNotification
-- calls on unlike continue to work correctly — they delete by actor+post+kind
-- which will still find and remove the single row.

-- ── 1. Reaction (post like) ───────────────────────────────────────────────

create or replace function public.notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  recipient_id uuid;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  select posts.author_id
    into recipient_id
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is null or recipient_id = new.user_id then
    return new;
  end if;

  -- Remove any prior notification for this actor+post+kind so re-liking
  -- doesn't stack up duplicate rows.
  delete from public.notifications
  where user_id   = recipient_id
    and actor_id  = new.user_id
    and post_id   = new.post_id
    and kind      = 'reaction';

  insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
  values (
    recipient_id,
    new.user_id,
    new.post_id,
    'reaction',
    coalesce(actor_name, 'Someone') || ' liked your post',
    coalesce(actor_name, 'Someone') || ' liked your post'
  );

  return new;
end;
$$;

-- ── Backfill: remove existing duplicate reaction notifications ───────────
-- For each (user_id, actor_id, post_id, kind='reaction') group that has more
-- than one row, keep only the most recent one.
delete from public.notifications
where kind = 'reaction'
  and id not in (
    select distinct on (user_id, actor_id, post_id)
      id
    from public.notifications
    where kind = 'reaction'
    order by user_id, actor_id, post_id, created_at desc
  );

-- ── 2. Comment like ───────────────────────────────────────────────────────

create or replace function public.notify_on_comment_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  recipient_id uuid;
  related_post_id uuid;
  comment_excerpt text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  select c.author_id, c.post_id, left(c.body, 160)
    into recipient_id, related_post_id, comment_excerpt
  from public.comments c
  where c.id = new.comment_id;

  if recipient_id is null or recipient_id = new.user_id then
    return new;
  end if;

  -- Remove any prior notification for this actor+comment+kind so re-liking
  -- a comment doesn't stack up duplicate rows.
  delete from public.notifications
  where user_id    = recipient_id
    and actor_id   = new.user_id
    and comment_id = new.comment_id
    and kind       = 'commentLike';

  insert into public.notifications (
    user_id,
    actor_id,
    post_id,
    comment_id,
    kind,
    title,
    detail
  ) values (
    recipient_id,
    new.user_id,
    related_post_id,
    new.comment_id,
    'commentLike',
    coalesce(actor_name, 'Someone') || ' liked your comment',
    coalesce(comment_excerpt, '')
  );

  return new;
end;
$$;

-- ── Backfill: remove existing duplicate commentLike notifications ─────────
delete from public.notifications
where kind = 'commentLike'
  and id not in (
    select distinct on (user_id, actor_id, comment_id)
      id
    from public.notifications
    where kind = 'commentLike'
    order by user_id, actor_id, comment_id, created_at desc
  );
