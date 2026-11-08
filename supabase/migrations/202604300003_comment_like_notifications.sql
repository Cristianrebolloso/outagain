-- Persist comment likes and notify the comment author immediately.
--
-- Before this migration, comment likes existed only in local UI state, so:
--   * likes disappeared on refresh,
--   * other devices never saw them, and
--   * the comment author could never receive a phone notification.
--
-- This migration makes comment likes first-class backend data and fans out a
-- `commentLike` notification row on insert, which the existing push trigger
-- then delivers to APNs within seconds.

create table if not exists public.comment_likes (
  id uuid primary key default gen_random_uuid(),
  comment_id uuid not null references public.comments (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now()),
  unique (comment_id, user_id)
);

create index if not exists comment_likes_comment_created_at_idx
  on public.comment_likes (comment_id, created_at desc);

create index if not exists comment_likes_user_created_at_idx
  on public.comment_likes (user_id, created_at desc);

alter table public.comment_likes enable row level security;

drop policy if exists "comment likes readable with parent post" on public.comment_likes;
create policy "comment likes readable with parent post"
on public.comment_likes
for select
to authenticated
using (
  exists (
    select 1
    from public.comments c
    join public.posts p on p.id = c.post_id
    where c.id = comment_likes.comment_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

drop policy if exists "users can create own comment likes" on public.comment_likes;
create policy "users can create own comment likes"
on public.comment_likes
for insert
to authenticated
with check (
  auth.uid() = user_id
  and exists (
    select 1
    from public.comments c
    join public.posts p on p.id = c.post_id
    where c.id = comment_likes.comment_id
      and (
        p.author_id = auth.uid()
        or public.is_friend(auth.uid(), p.author_id)
      )
  )
);

drop policy if exists "users can delete own comment likes" on public.comment_likes;
create policy "users can delete own comment likes"
on public.comment_likes
for delete
to authenticated
using (auth.uid() = user_id);

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

  if recipient_id is not null and recipient_id <> new.user_id then
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
  end if;

  return new;
end;
$$;

drop trigger if exists comment_likes_notify_insert on public.comment_likes;
create trigger comment_likes_notify_insert
after insert on public.comment_likes
for each row
execute procedure public.notify_on_comment_like();
