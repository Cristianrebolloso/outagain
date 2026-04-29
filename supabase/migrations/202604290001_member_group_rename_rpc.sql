-- Allow any current member of a night group to rename it.
--
-- The client already routes name-only edits through `renameNightGroup`, but
-- relying on direct PATCH + RLS has proven brittle across environments where
-- the expected `member_update` policy wasn't present or wasn't behaving as
-- intended. This RPC makes the rule explicit and stable:
--   - caller must be authenticated
--   - caller must currently be in member_ids
--   - only the group's name is mutable via this path

create or replace function public.rename_night_group(group_id uuid, new_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_name text := coalesce(trim(new_name), '');
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is null - sign-in required';
  end if;

  update public.night_groups
  set name = normalized_name
  where id = group_id
    and auth.uid() = any(member_ids);

  if not found then
    raise exception 'Only group members can rename this group';
  end if;
end;
$$;

grant execute on function public.rename_night_group(uuid, text) to authenticated;
