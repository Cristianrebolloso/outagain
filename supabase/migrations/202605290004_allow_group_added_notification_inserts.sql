-- Let the shipped client create group-added notification rows.
--
-- Night group creation is a direct insert into public.night_groups followed by
-- direct inserts into public.notifications for each newly added friend. The
-- group row succeeds under the night_groups RLS policy, but notifications had
-- no INSERT policy for this safe client fanout path.

grant insert on table public.notifications to authenticated;

drop policy if exists "members can insert group added notifications" on public.notifications;
create policy "members can insert group added notifications"
on public.notifications
for insert
to authenticated
with check (
  kind = 'groupAdded'
  and actor_id = auth.uid()
  and user_id <> auth.uid()
  and post_id is null
  and comment_id is null
  and read_at is null
  and public.is_friend(auth.uid(), user_id)
  and exists (
    select 1
    from public.night_groups ng
    where ng.created_at >= timezone('utc', now()) - interval '36 hours'
      and auth.uid() = any(ng.member_ids)
      and user_id = any(ng.member_ids)
  )
);
