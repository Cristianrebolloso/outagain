-- Allow users to permanently clear their own notifications.
--
-- The iOS app deletes notification rows when a user taps "Clear" in Activity.
-- Without a DELETE policy, PostgREST can return a successful empty delete
-- response under RLS, which makes the client think the clear worked until the
-- next refresh reloads the same rows.

drop policy if exists "users can delete own notifications" on public.notifications;
create policy "users can delete own notifications"
on public.notifications
for delete
to authenticated
using (auth.uid() = user_id);
