-- Tagged-profile post visibility.
--
-- Profile Tagged tabs query posts by `tagged_user_ids`, but the friend-only
-- RLS policy only considered the author. That made tagged grids incomplete
-- whenever the viewer could view the tagged profile but was not also friends
-- with the post author. Treat a tag as profile participation: admins, the
-- author, the tagged user, and accepted direct friends of either can read the
-- post.

create index if not exists posts_tagged_user_ids_gin_idx
  on public.posts using gin (tagged_user_ids);

create or replace function public.can_read_post(
  post_author_id uuid,
  post_tagged_user_ids uuid[]
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_app_admin(auth.uid())
    or post_author_id = auth.uid()
    or public.is_friend(auth.uid(), post_author_id)
    or auth.uid() = any(coalesce(post_tagged_user_ids, '{}'::uuid[]))
    or exists (
      select 1
      from public.friendships f
      where f.status = 'accepted'
        and (
          (f.user_id = auth.uid() and f.friend_id = any(coalesce(post_tagged_user_ids, '{}'::uuid[])))
          or (f.friend_id = auth.uid() and f.user_id = any(coalesce(post_tagged_user_ids, '{}'::uuid[])))
        )
    );
$$;

grant execute on function public.can_read_post(uuid, uuid[]) to authenticated;

drop policy if exists "posts readable to author and direct friends" on public.posts;
drop policy if exists "posts readable to author and friends" on public.posts;
drop policy if exists "posts readable to author and tagged friends" on public.posts;

create policy "posts readable to author and tagged friends"
on public.posts
for select
to authenticated
using (public.can_read_post(author_id, tagged_user_ids));

drop policy if exists "comments readable with direct-friend parent post" on public.comments;
drop policy if exists "comments readable with parent post" on public.comments;
drop policy if exists "comments readable with tagged parent post" on public.comments;

create policy "comments readable with tagged parent post"
on public.comments
for select
to authenticated
using (
  exists (
    select 1
    from public.posts p
    where p.id = comments.post_id
      and public.can_read_post(p.author_id, p.tagged_user_ids)
  )
);

drop policy if exists "reactions readable with direct-friend parent post" on public.reactions;
drop policy if exists "reactions readable with parent post" on public.reactions;
drop policy if exists "reactions readable with tagged parent post" on public.reactions;

create policy "reactions readable with tagged parent post"
on public.reactions
for select
to authenticated
using (
  exists (
    select 1
    from public.posts p
    where p.id = reactions.post_id
      and public.can_read_post(p.author_id, p.tagged_user_ids)
  )
);

drop policy if exists "comment likes readable with parent post" on public.comment_likes;
drop policy if exists "comment likes readable with tagged parent post" on public.comment_likes;

create policy "comment likes readable with tagged parent post"
on public.comment_likes
for select
to authenticated
using (
  exists (
    select 1
    from public.comments c
    join public.posts p on p.id = c.post_id
    where c.id = comment_likes.comment_id
      and public.can_read_post(p.author_id, p.tagged_user_ids)
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
      and public.can_read_post(p.author_id, p.tagged_user_ids)
  )
);
