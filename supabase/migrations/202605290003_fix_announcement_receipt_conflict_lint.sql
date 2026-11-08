-- Avoid PL/pgSQL ambiguity in the announcement receipt upsert.

create or replace function public.mark_app_announcement_seen(announcement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  viewer_id uuid := auth.uid();
begin
  if viewer_id is null then
    raise exception 'Not authenticated.';
  end if;

  insert into public.app_announcement_receipts (announcement_id, user_id, seen_at)
  select a.id, viewer_id, now()
  from public.app_announcements a
  where a.id = $1
    and (
      a.target_user_ids is null
      or cardinality(a.target_user_ids) = 0
      or viewer_id = any(a.target_user_ids)
    )
  on conflict on constraint app_announcement_receipts_pkey
  do update set seen_at = excluded.seen_at;
end;
$$;

revoke all on function public.mark_app_announcement_seen(uuid) from public;
revoke all on function public.mark_app_announcement_seen(uuid) from anon;
grant execute on function public.mark_app_announcement_seen(uuid) to authenticated;
