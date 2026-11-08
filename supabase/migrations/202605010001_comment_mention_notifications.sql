-- Comment mention support.
--
-- Adds `mentioned_user_ids` to comments so exact @username mentions can be
-- stored alongside the comment itself, then fans out one notification per
-- mentioned user. Because the existing notifications->APNs trigger already
-- runs on every inserted notification row, mentioned users get a push within
-- the same immediate path as post tags, likes, and replies.

alter table public.comments
  add column if not exists mentioned_user_ids uuid[] not null default '{}';

create or replace function public.notify_on_comment_mentions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  mentioned_uid uuid;
  notification_detail text;
begin
  if new.mentioned_user_ids is null or array_length(new.mentioned_user_ids, 1) is null then
    return new;
  end if;

  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.author_id;

  notification_detail := left(new.body, 160);

  for mentioned_uid in
    select distinct unnest(new.mentioned_user_ids)
  loop
    continue when mentioned_uid = new.author_id;

    insert into public.notifications (user_id, actor_id, post_id, comment_id, kind, title, detail)
    values (
      mentioned_uid,
      new.author_id,
      new.post_id,
      new.id,
      'commentTagged',
      coalesce(actor_name, 'Someone') || ' mentioned you in a comment',
      notification_detail
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists comments_notify_mentions on public.comments;
create trigger comments_notify_mentions
after insert on public.comments
for each row
execute procedure public.notify_on_comment_mentions();
