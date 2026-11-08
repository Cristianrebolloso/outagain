-- Close the night_groups member_ids rewrite hole.
--
-- Direct UPDATE policies let any current member replace the full member_ids
-- array. Keep collaborative renaming through rename_night_group, but move
-- membership additions behind update_night_group so existing members cannot be
-- removed and newly-added users must be accepted friends of the caller.

alter table public.night_groups enable row level security;

drop policy if exists "creator_update" on public.night_groups;
drop policy if exists "member_update" on public.night_groups;

create or replace function public.update_night_group(
  group_id uuid,
  new_name text,
  new_member_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  requested_group_id alias for $1;
  requested_name alias for $2;
  requested_member_ids_input alias for $3;
  caller_id uuid := auth.uid();
  normalized_name text := coalesce(trim(requested_name), '');
  existing_member_ids uuid[] := array[]::uuid[];
  requested_member_ids uuid[] := array[]::uuid[];
  requested_additions uuid[] := array[]::uuid[];
  invalid_member_ids uuid[] := array[]::uuid[];
begin
  if caller_id is null then
    raise exception 'auth.uid() is null - sign-in required' using errcode = '42501';
  end if;

  select ng.member_ids
  into existing_member_ids
  from public.night_groups ng
  where ng.id = requested_group_id
  for update;

  if not found then
    raise exception 'No night group found.';
  end if;

  if not caller_id = any(existing_member_ids) then
    raise exception 'Only group members can update this group.' using errcode = '42501';
  end if;

  select coalesce(array_agg(member_id order by first_seen), array[]::uuid[])
  into requested_member_ids
  from (
    select input.member_id, min(input.ordinality) as first_seen
    from unnest(coalesce(requested_member_ids_input, array[]::uuid[]))
      with ordinality as input(member_id, ordinality)
    where input.member_id is not null
    group by input.member_id
  ) deduped;

  select coalesce(array_agg(member_id order by first_seen), array[]::uuid[])
  into requested_additions
  from (
    select input.member_id, min(input.ordinality) as first_seen
    from unnest(requested_member_ids)
      with ordinality as input(member_id, ordinality)
    where input.member_id is not null
      and not input.member_id = any(existing_member_ids)
    group by input.member_id
  ) additions;

  select coalesce(array_agg(member_id), array[]::uuid[])
  into invalid_member_ids
  from unnest(requested_additions) as addition(member_id)
  where not exists (
    select 1
    from public.friendships f
    where f.status = 'accepted'
      and (
        (f.user_id = caller_id and f.friend_id = addition.member_id)
        or
        (f.friend_id = caller_id and f.user_id = addition.member_id)
      )
  );

  if cardinality(invalid_member_ids) > 0 then
    raise exception 'Only accepted friends can be added to a night group.'
      using errcode = '42501';
  end if;

  update public.night_groups ng
  set name = normalized_name,
      member_ids = existing_member_ids || requested_additions
  where ng.id = requested_group_id;
end;
$$;

revoke all on function public.update_night_group(uuid, text, uuid[]) from public;
revoke all on function public.update_night_group(uuid, text, uuid[]) from anon;
grant execute on function public.update_night_group(uuid, text, uuid[]) to authenticated;
