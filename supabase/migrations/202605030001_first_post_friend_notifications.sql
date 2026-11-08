-- Restore friend-post notifications, limited to first post per 24-hour cycle.
--
-- Cycle definition: each day resets at 07:00 local time. Because the database
-- runs in UTC we anchor the cycle to 07:00 America/Chicago (Central Time),
-- which is what the product team uses as the reference timezone. Adjust the
-- AT TIME ZONE expression below if the canonical timezone changes.
--
-- Deduplication logic:
--   Before fanning out, check whether the author already triggered a
--   friendPost notification during the current cycle (cycle_start <= created_at
--   < cycle_start + 24h). If a row exists, skip the entire fan-out. This means
--   only the first post after 07:00 generates notifications to friends; all
--   subsequent posts in the same cycle are silent.
--
-- Example:
--   Post at  8pm Friday  → first post of Friday cycle  → fans out  ✓
--   Post at  9pm Friday  → second post same cycle       → suppressed ✗
--   Post at  7pm Saturday → first post of Saturday cycle → fans out ✓
--
-- The previous migration (202605020001) dropped the trigger and deleted all
-- existing friendPost rows. This migration re-creates the trigger function
-- and trigger with the new guard in place.

create or replace function public.notify_on_post()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name   text;
  cycle_start  timestamptz;
  already_sent boolean;
begin
  -- ----------------------------------------------------------------
  -- 1. Compute the start of the current 24-hour notification cycle.
  --    The cycle begins at 07:00 America/Chicago each calendar day.
  --    We convert the post timestamp to Central Time, floor to the
  --    current date, add 7 hours, then convert back to UTC.
  -- ----------------------------------------------------------------
  cycle_start := date_trunc('day', new.created_at at time zone 'America/Chicago')
                   + interval '7 hours';
  -- If the post was published before 07:00 Central on its calendar date,
  -- it actually belongs to the *previous* day's cycle.
  if new.created_at < cycle_start then
    cycle_start := cycle_start - interval '24 hours';
  end if;

  -- ----------------------------------------------------------------
  -- 2. Deduplication guard: has this author already triggered a
  --    friendPost fan-out in the current cycle?
  -- ----------------------------------------------------------------
  select exists (
    select 1
    from public.notifications
    where actor_id = new.author_id
      and kind      = 'friendPost'
      and created_at >= cycle_start
      and created_at <  cycle_start + interval '24 hours'
    limit 1
  ) into already_sent;

  if already_sent then
    return new;  -- silent — not the first post of the cycle
  end if;

  -- ----------------------------------------------------------------
  -- 3. First post of this cycle: resolve display name and fan out.
  -- ----------------------------------------------------------------
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
  ) friends
  where friend_user_id <> new.author_id;

  return new;
end;
$$;

-- Re-attach the trigger (was dropped by 202605020001).
drop trigger if exists posts_notify_insert on public.posts;
create trigger posts_notify_insert
after insert on public.posts
for each row
execute procedure public.notify_on_post();
