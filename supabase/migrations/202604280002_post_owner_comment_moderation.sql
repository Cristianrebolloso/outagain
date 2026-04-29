-- Allow post authors to moderate comments left on their own posts.
-- Comment authors keep delete rights; this adds a second valid delete path.

drop policy if exists "authors can delete own comments" on public.comments;
drop policy if exists "comment authors or post authors can delete comments" on public.comments;

create policy "comment authors or post authors can delete comments"
on public.comments
for delete
to authenticated
using (
  auth.uid() = author_id
  or exists (
    select 1 from public.posts p
    where p.id = comments.post_id
      and p.author_id = auth.uid()
  )
);
