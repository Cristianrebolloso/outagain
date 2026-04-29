-- Fix reaction notification detail text.
-- Previously: "Cheers on your Beer." — exposes drink name and uses "Cheers"
-- as a verb which reads awkwardly and surfaces the drink in a notification
-- the recipient might see in a public context.
-- Now: just the title text, no drink name in the body.

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

  if recipient_id is not null and recipient_id <> new.user_id then
    insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
    values (
      recipient_id,
      new.user_id,
      new.post_id,
      'reaction',
      coalesce(actor_name, 'Someone') || ' liked your post',
      coalesce(actor_name, 'Someone') || ' liked your post'
    );
  end if;

  return new;
end;
$$;
