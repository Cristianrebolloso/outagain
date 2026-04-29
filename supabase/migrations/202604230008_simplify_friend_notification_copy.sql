-- Simplify friend-request and friend-accept notification copy.
--
-- The previous copy — "Cristian wants to be friends" / "Tap to accept or
-- ignore." — reads like a 2012 Facebook nudge: softened, passive, two-line.
-- APNs truncates aggressively and the user's instinct when a push lands is
-- to parse the first four words. Direct, declarative copy wins:
--
--   "Cristian sent you a friend request"
--   "Cristian accepted your friend request"
--
-- We intentionally drop the detail line entirely for friend-request (empty
-- string rather than null, because the client renders detail verbatim and
-- a nil check adds branching we don't need). The title is the signal; the
-- tap target is obvious; any additional copy is noise. Same treatment for
-- friend-accept — the title already tells the full story.
--
-- This migration only rewrites the two functions. The triggers that call
-- them (friendships_notify_request_insert, friendships_notify_accept_update)
-- were installed in 202604230004 and don't need to be touched; they keep
-- firing and pick up the new function body immediately.
--
-- Second-order note: once the server copy is terse, the iOS notification
-- row renderer should stop padding a secondary line when detail is empty.
-- That's a client change tracked separately; until it lands, an empty
-- detail still renders cleanly as a single-line notification row.

create or replace function public.notify_on_friend_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  -- Only fire for genuinely new pending requests. The friendships table
  -- receives upserts from both directions of the handshake, so we guard
  -- against a redundant insert producing a duplicate notification.
  if new.status <> 'pending' then
    return new;
  end if;

  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  insert into public.notifications (user_id, actor_id, kind, title, detail)
  values (
    new.friend_id,
    new.user_id,
    'friendRequest',
    coalesce(actor_name, 'Someone') || ' sent you a friend request',
    ''
  );

  return new;
end;
$$;

create or replace function public.notify_on_friend_accept()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  -- Only fire on the pending -> accepted transition. Any other status
  -- change (block, remove) should not emit an acceptance notification.
  if new.status <> 'accepted' or old.status = 'accepted' then
    return new;
  end if;

  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.friend_id;

  insert into public.notifications (user_id, actor_id, kind, title, detail)
  values (
    new.user_id,
    new.friend_id,
    'friendAccepted',
    coalesce(actor_name, 'Someone') || ' accepted your friend request',
    ''
  );

  return new;
end;
$$;
