-- Rename "moment" → "post" in all user-facing notification copy.
--
-- Three locations:
--   1. Existing notification rows already in the DB (backfill).
--   2. notify_on_reaction()  — "liked your post" (already fixed in 001, this re-applies cleanly).
--   3. notify_on_comment()   — "commented on your post".
--   4. notify_on_friend_accept() — "You can now see each other's posts."
--   5. friend_post_fanout trigger detail — "A new post" instead of "A new moment".

-- ─── 1. Backfill existing rows ───────────────────────────────────────────────

update public.notifications
set title = replace(title, 'your moment', 'your post')
where title like '%your moment%';

update public.notifications
set detail = replace(detail, 'your moment', 'your post')
where detail like '%your moment%';

update public.notifications
set detail = replace(detail, 'each other''s moments', 'each other''s posts')
where detail like '%each other''s moments%';

update public.notifications
set detail = replace(detail, 'A new moment', 'A new post')
where detail like '%A new moment%';

-- ─── 2. notify_on_reaction — "liked your post" ───────────────────────────────

create or replace function public.notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  recipient_id uuid;
  drink_name text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  select posts.author_id, posts.drink_name
    into recipient_id, drink_name
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is not null and recipient_id <> new.user_id then
    insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
    values (
      recipient_id,
      new.user_id,
      new.post_id,
      'reaction',
      coalesce(actor_name, 'Someone') || ' liked your post',
      initcap(new.kind) || ' on your ' || coalesce(drink_name, 'post') || '.'
    );
  end if;

  return new;
end;
$$;

-- ─── 3. notify_on_comment — "commented on your post" ────────────────────────

create or replace function public.notify_on_comment()
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
  where profiles.id = new.author_id;

  select posts.author_id
    into recipient_id
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is not null and recipient_id <> new.author_id then
    insert into public.notifications (user_id, actor_id, post_id, comment_id, kind, title, detail)
    values (
      recipient_id,
      new.author_id,
      new.post_id,
      new.id,
      case when new.kind = 'photo' then 'photoReply' else 'comment' end,
      coalesce(actor_name, 'Someone') || ' commented on your post',
      left(new.body, 160)
    );
  end if;

  return new;
end;
$$;

-- ─── 4. notify_on_friend_accept — "each other's posts" ──────────────────────

create or replace function public.notify_on_friend_accept()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.friend_id;

  if new.status = 'accepted' then
    insert into public.notifications (user_id, actor_id, kind, title, detail)
    values (
      new.user_id,
      new.friend_id,
      'friendAccepted',
      coalesce(actor_name, 'Someone') || ' accepted your friend request',
      'You can now see each other''s posts.'
    );
  end if;
  return new;
end;
$$;

-- ─── 5. friend_post_fanout — "A new post" ───────────────────────────────────

create or replace function public.notify_friends_on_post()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.author_id;

  insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
  select
    friend_user_id,
    new.author_id,
    new.id,
    'friendPost',
    coalesce(actor_name, 'A friend') || ' just posted',
    coalesce(new.drink_name, 'A new post') ||
      case when new.venue_name is not null then ' at ' || new.venue_name else '' end
  from (
    select friend_id as friend_user_id
    from public.friendships
    where user_id = new.author_id and status = 'accepted'
    union
    select user_id as friend_user_id
    from public.friendships
    where friend_id = new.author_id and status = 'accepted'
  ) friends;

  return new;
end;
$$;
