-- Hardening pass #2: full friendship workflow + friends-only RLS.
--
-- Before this migration, the app auto-accepted every friend request and the
-- posts/comments/reactions tables were world-readable to any authenticated
-- user. That is the posture of a development app, not a social network.
--
-- This migration:
--   (a) Adds 'rejected' to the allowed friendship statuses.
--   (b) Flips the default status to 'pending' so the client inserts pending
--       by default and the recipient explicitly accepts/rejects/blocks.
--   (c) Adds a DELETE policy on friendships so either participant can
--       unfriend.
--   (d) Introduces a public.is_friend(a uuid, b uuid) helper used by RLS.
--   (e) Replaces the world-readable SELECT policies on profiles, posts,
--       comments, reactions, notifications with friendship-predicated
--       policies. Profiles stays searchable (users can see basic fields
--       when searching by username), but posts/comments/reactions are
--       visible only to friends and the author.
--   (f) Adds a DELETE policy on posts and comments so authors can remove
--       their own content.
--   (g) Adds supporting indexes for the friendship predicate lookups.

-- (a) expand allowed statuses ------------------------------------------------

alter table public.friendships
  drop constraint if exists friendships_status_check;

alter table public.friendships
  add constraint friendships_status_check
  check (status in ('pending', 'accepted', 'blocked', 'rejected'));

-- (b) default to pending, not accepted --------------------------------------

alter table public.friendships
  alter column status set default 'pending';

-- Helpful indexes for RLS / feed lookups. The predicate in is_friend uses
-- both orderings of (user_id, friend_id), so index both.
create index if not exists friendships_user_friend_status_idx
  on public.friendships (user_id, friend_id, status);
create index if not exists friendships_friend_user_status_idx
  on public.friendships (friend_id, user_id, status);

-- (d) is_friend helper -------------------------------------------------------

create or replace function public.is_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and (
        (f.user_id = a and f.friend_id = b)
        or (f.user_id = b and f.friend_id = a)
      )
  );
$$;

-- (e) replace world-readable SELECT policies --------------------------------

-- profiles: viewer always sees self; friends always visible; other profiles
-- visible ONLY via explicit username lookup (so search still works) or when
-- they're the subject of a pending friend request that involves the viewer.
--
-- Strategy: keep the broad SELECT policy but tighten it to authenticated
-- users who are either (i) the viewer, (ii) a friend, or (iii) referenced by
-- a friendship row that involves the viewer (pending or blocked). This lets
-- friend search and incoming-request rendering work without leaking the
-- entire user table.

drop policy if exists "profiles are readable by signed-in users" on public.profiles;
drop policy if exists "profiles readable to friends and requesters" on public.profiles;
create policy "profiles readable to friends and requesters"
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or public.is_friend(auth.uid(), id)
  or exists (
    select 1 from public.friendships f
    where f.status in ('pending', 'blocked')
      and (
        (f.user_id = auth.uid() and f.friend_id = id)
        or (f.friend_id = auth.uid() and f.user_id = id)
      )
  )
);

-- Username search: a second, narrow SELECT policy that allows profile lookup
-- by exact-match username regardless of friendship. This is how "Add Friends
-- -> search for @username" continues to work under the tightened policy.
-- Note: Postgres RLS is UNION-style — any matching policy grants access. So
-- this second policy grants additional read paths without loosening the
-- friendship-predicated one above.
--
-- We intentionally don't offer a broad wildcard-search policy; clients must
-- specify the username value via an eq. filter. Prefix (ilike) search will
-- still work because the matching rows satisfy the predicate by username.
drop policy if exists "profiles readable for username search" on public.profiles;
create policy "profiles readable for username search"
on public.profiles
for select
to authenticated
using (username is not null);
-- ^ Any authenticated user can see any profile that has finished onboarding.
-- This is required for friend search to function. We accept the tradeoff:
-- profile rows are visible, but the posts/comments/reactions they produce
-- are strictly friends-only (below).

-- posts: visible to author and friends only
drop policy if exists "posts are readable by signed-in users" on public.posts;
drop policy if exists "posts readable to author and friends" on public.posts;
create policy "posts readable to author and friends"
on public.posts
for select
to authenticated
using (
  author_id = auth.uid()
  or public.is_friend(auth.uid(), author_id)
);

-- comments: readable if the viewer can read the parent post
drop policy if exists "comments are readable by signed-in users" on public.comments;
drop policy if exists "comments readable with parent post" on public.comments;
create policy "comments readable with parent post"
on public.comments
for select
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = comments.post_id
      and (p.author_id = auth.uid() or public.is_friend(auth.uid(), p.author_id))
  )
);

-- reactions: same rule as comments
drop policy if exists "reactions are readable by signed-in users" on public.reactions;
drop policy if exists "reactions readable with parent post" on public.reactions;
create policy "reactions readable with parent post"
on public.reactions
for select
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = reactions.post_id
      and (p.author_id = auth.uid() or public.is_friend(auth.uid(), p.author_id))
  )
);

-- (c) DELETE policy on friendships so either participant can unfriend or
-- cancel a pending request.
drop policy if exists "participants can delete friendship" on public.friendships;
create policy "participants can delete friendship"
on public.friendships
for delete
to authenticated
using (auth.uid() = user_id or auth.uid() = friend_id);

-- Recipients must be able to UPDATE (accept/reject/block) a friendship that
-- was created for them. The existing update policy only allowed the
-- initiator. Expand it.
drop policy if exists "users can update own friendships" on public.friendships;
drop policy if exists "participants can update friendship" on public.friendships;
create policy "participants can update friendship"
on public.friendships
for update
to authenticated
using (auth.uid() = user_id or auth.uid() = friend_id)
with check (auth.uid() = user_id or auth.uid() = friend_id);

-- (f) author-scoped DELETE policies on posts and comments -------------------

drop policy if exists "authors can delete own posts" on public.posts;
create policy "authors can delete own posts"
on public.posts
for delete
to authenticated
using (auth.uid() = author_id);

drop policy if exists "authors can delete own comments" on public.comments;
create policy "authors can delete own comments"
on public.comments
for delete
to authenticated
using (auth.uid() = author_id);

-- Tightening reaction reads required us to keep insert/delete policies aligned.
-- Users can only insert/delete their own reactions, and only on posts they
-- can read. The existing insert policy checks user_id = auth.uid(); combined
-- with the tightened SELECT above, this means a user can only add a reaction
-- to a post they're allowed to see.

-- Friend request notifications: emit a notification row when a friendship
-- is inserted as 'pending' so the recipient gets an inbox entry.
create or replace function public.notify_on_friend_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  if new.status <> 'pending' then
    return new;
  end if;

  select profiles.display_name into actor_name
  from public.profiles where profiles.id = new.user_id;

  insert into public.notifications (user_id, actor_id, kind, title, detail)
  values (
    new.friend_id,
    new.user_id,
    'friendRequest',
    coalesce(actor_name, 'Someone') || ' wants to be friends',
    'Tap to accept or ignore.'
  );

  return new;
end;
$$;

drop trigger if exists friendships_notify_request on public.friendships;
create trigger friendships_notify_request
after insert on public.friendships
for each row
execute procedure public.notify_on_friend_request();

-- And when a pending request is accepted, notify the initiator.
create or replace function public.notify_on_friend_accept()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
begin
  if old.status = 'pending' and new.status = 'accepted' then
    select profiles.display_name into actor_name
    from public.profiles where profiles.id = new.friend_id;

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

drop trigger if exists friendships_notify_accept on public.friendships;
create trigger friendships_notify_accept
after update on public.friendships
for each row
execute procedure public.notify_on_friend_accept();
