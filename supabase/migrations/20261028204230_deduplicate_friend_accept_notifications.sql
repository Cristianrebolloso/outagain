-- A PATCH may be retried after the response is lost. Notify only when the
-- relationship actually becomes accepted, never on accepted-to-accepted writes.
drop trigger if exists friendships_notify_accept on public.friendships;
create trigger friendships_notify_accept after update on public.friendships
for each row
when (new.status = 'accepted' and old.status is distinct from new.status)
execute function public.notify_on_friend_accept();
