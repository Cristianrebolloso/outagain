-- Make posts readable by any authenticated user so that non-friends can
-- browse a user's profile grid. Previously the SELECT policy required the
-- viewer to be the author, a direct friend, or a friend-of-friend, which
-- meant a stranger opening a profile via search or an invite link always
-- saw 0 posts even though the app intentionally supports public browsing.
--
-- We keep the same broadened rule for comments and reactions so that post
-- detail views work correctly for non-friends too.

-- Posts: readable by any authenticated user
drop policy if exists "posts readable to author and friends" on public.posts;
create policy "posts readable to any authenticated user"
on public.posts
for select
to authenticated
using (true);

-- Comments: readable if the parent post is readable (which it now always is
-- for authenticated users, so this simplifies to authenticated = true).
drop policy if exists "comments readable with parent post" on public.comments;
create policy "comments readable to any authenticated user"
on public.comments
for select
to authenticated
using (true);

-- Reactions: same simplification.
drop policy if exists "reactions readable with parent post" on public.reactions;
create policy "reactions readable to any authenticated user"
on public.reactions
for select
to authenticated
using (true);
