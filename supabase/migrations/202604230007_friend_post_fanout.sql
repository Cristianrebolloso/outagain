-- Friend-post fanout.
--
-- When a user posts, every accepted friend gets a notification row in
-- public.notifications so (a) they see it in-app on next refresh and
-- (b) the pg_net push-dispatch trigger delivers an APNs push. Without
-- this, the app is missing the single highest-leverage notification
-- for retention: "your friend just posted, come see."
--
-- Design choices worth naming:
--
--   * We fan out at post-insert time rather than computing the fan-out
--     on read. Pre-computing keeps the in-app notification feed fast
--     (single indexed query by user_id) and matches how the reaction /
--     comment triggers already work.
--
--   * We only notify accepted friends in either direction of the
--     friendships table — not pending requests, not blocked. The
--     is_friend() helper already encodes that asymmetric-storage rule.
--
--   * actor_id points at the author, post_id at the new post, kind is
--     'friendPost' so the client can render it with the right icon and
--     route taps into the post detail.
--
--   * Title / detail are kept short: APNs truncates aggressively and a
--     verbose "Cristian just posted a Beer at Dive Bar Downtown" loses
--     the part that drives a tap ("Cristian posted") to overflow.

create or replace function public.notify_on_post()
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

  -- Insert one notification per accepted friend. Friendships are
  -- stored with one row per direction in some flows and two rows in
  -- others, so we union both sides and distinct out duplicates to be
  -- safe against either shape.
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
  ) friends
  where friend_user_id <> new.author_id;

  return new;
end;
$$;

drop trigger if exists posts_notify_insert on public.posts;
create trigger posts_notify_insert
after insert on public.posts
for each row
execute procedure public.notify_on_post();
