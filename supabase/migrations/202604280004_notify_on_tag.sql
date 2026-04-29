-- Tag notification fan-out.
--
-- When a post is created with one or more tagged_user_ids, each tagged user
-- receives a notification row (kind = 'tagged'). The existing
-- dispatch_notification_push trigger on public.notifications already handles
-- delivery to APNs, so no additional push infrastructure is needed here.
--
-- Design notes:
--   * We notify only users who are in tagged_user_ids and are NOT the author
--     themselves (self-tagging edge case).
--   * We do NOT gate on friendship status intentionally — if the author can
--     tag someone, that person should hear about it regardless of whether the
--     friendship has been accepted yet. RLS on the posts table already ensures
--     only authorized users can be tagged.
--   * The title/detail copy mirrors the iOS client's presenceNote pattern:
--     "[Author] added you to a post" / "[drink] at [venue]" or just "[drink]".
--   * This trigger fires AFTER the posts_notify_insert trigger (notify_on_post),
--     which fans out to the author's friend list. Tagged users who are already
--     friends of the author will receive TWO notifications for the same post:
--     one 'friendPost' (from notify_on_post) and one 'tagged'. This is
--     intentional — being tagged is a higher-signal event and deserves its own
--     notification even if you'd have seen a friendPost anyway.
--   * If that double-notification turns out to be noisy in practice, add a
--     WHERE NOT EXISTS guard (see commented variant below) to suppress the
--     friendPost row for tagged friends. We start without it to keep the
--     trigger simple and add it if users report it.

create or replace function public.notify_on_tag()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  tag_detail text;
  tagged_uid uuid;
begin
  -- Nothing to do if no one is tagged.
  if new.tagged_user_ids is null or array_length(new.tagged_user_ids, 1) is null then
    return new;
  end if;

  select display_name into actor_name
  from public.profiles
  where id = new.author_id;

  -- Build the detail line: "[drink] at [venue]" or just "[drink]".
  tag_detail := coalesce(new.drink_name, 'A post') ||
    case
      when new.venue_name is not null then ' at ' || new.venue_name
      else ''
    end;

  -- Fan out one notification per tagged user, skipping the author.
  foreach tagged_uid in array new.tagged_user_ids
  loop
    -- Skip self-tags.
    continue when tagged_uid = new.author_id;

    insert into public.notifications (
      user_id,
      actor_id,
      post_id,
      kind,
      title,
      detail
    ) values (
      tagged_uid,
      new.author_id,
      new.id,
      'tagged',
      coalesce(actor_name, 'Someone') || ' added you to a post',
      tag_detail
    );
  end loop;

  return new;
end;
$$;

-- Fire AFTER posts_notify_insert so the friendPost fan-out runs first and
-- tagged notifications land in a predictable order in the recipient's feed.
drop trigger if exists posts_notify_tag on public.posts;
create trigger posts_notify_tag
after insert on public.posts
for each row
execute procedure public.notify_on_tag();

-- ── Optional: suppress duplicate friendPost for tagged friends ───────────────
-- If you later decide that friends who are also tagged should only receive the
-- 'tagged' notification (not both), replace notify_on_post with this variant
-- that skips already-tagged recipients:
--
-- ... WHERE friend_user_id <> new.author_id
--       AND NOT (friend_user_id = ANY(new.tagged_user_ids))
--
-- Leave commented out for now; activate if double-notification feedback emerges.
