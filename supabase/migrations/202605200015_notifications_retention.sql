-- Bound notifications table growth. Without retention, every reaction,
-- comment, friend-request, tag, and verification event lives forever.
-- Mirrors the pattern from prune_old_push_attempts (202604270001) — fires
-- as a statement-level trigger on insert so the cleanup amortizes across
-- normal write traffic without needing pg_cron.

create or replace function public.prune_old_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Delete read notifications older than 60 days, in a small batch to
  -- avoid lock contention with concurrent inserts.
  delete from public.notifications
  where id in (
    select id from public.notifications
    where read_at is not null
      and created_at < now() - interval '60 days'
    limit 100
  );

  -- Also clear unread notifications older than 180 days. These belong to
  -- abandoned accounts or notifications the user never opened — at that
  -- age they have no actionable value.
  delete from public.notifications
  where id in (
    select id from public.notifications
    where read_at is null
      and created_at < now() - interval '180 days'
    limit 50
  );

  return new;
end;
$$;

drop trigger if exists notifications_prune on public.notifications;
create trigger notifications_prune
after insert on public.notifications
for each statement
execute procedure public.prune_old_notifications();

-- Index supporting the prune query's predicate.
create index if not exists notifications_read_at_created_at_idx
  on public.notifications (read_at, created_at)
  where read_at is not null;
