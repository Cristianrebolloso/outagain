-- Let any current member rename or otherwise update a night group while
-- preserving the original creator_id.
--
-- Some environments still appear to have the older creator-only update
-- posture, which makes member rename attempts silently fail via RLS.

alter table public.night_groups enable row level security;

drop policy if exists "creator_update" on public.night_groups;
drop policy if exists "member_update" on public.night_groups;

create policy "member_update"
on public.night_groups
for update
to authenticated
using (auth.uid() = any(member_ids))
with check (
  auth.uid() = any(member_ids)
  and creator_id = (select ng2.creator_id from public.night_groups ng2 where ng2.id = night_groups.id)
);
