-- Friend-post notifications created too much weekend noise.
--
-- We keep post visibility and feed loading unchanged; this only removes the
-- notification fan-out that created `friendPost` rows for every accepted
-- friend whenever someone posted.

drop trigger if exists posts_notify_insert on public.posts;

delete from public.notifications
where kind = 'friendPost';
