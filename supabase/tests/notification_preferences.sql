-- Run inside BEGIN/ROLLBACK. No pushes or committed preference changes.
do $$
declare member_id uuid; other_id uuid;
begin
  select id into member_id from public.profiles order by id limit 1;
  select id into other_id from public.profiles where id <> member_id order by id limit 1;
  assert member_id is not null and other_id is not null, 'Test accounts unavailable';
  perform set_config('test.preferences_member_id', member_id::text, true);
  perform set_config('test.preferences_other_id', other_id::text, true);
  delete from public.notification_preferences where user_id in (member_id, other_id);
  insert into public.notification_preferences(user_id) values (member_id), (other_id);
  assert (select announcements_enabled and friend_requests_enabled and reactions_enabled and comments_enabled and activity_enabled
    from public.notification_preferences where user_id = member_id), 'New rows must default entirely on';
  update public.notification_preferences set announcements_enabled = false where user_id = member_id;
  -- Matches a partial PostgREST upsert: only a supplied column is updated.
  insert into public.notification_preferences(user_id, comments_enabled) values (member_id, false)
    on conflict (user_id) do update set comments_enabled = excluded.comments_enabled;
  assert (select not announcements_enabled and not comments_enabled and friend_requests_enabled and reactions_enabled and activity_enabled
    from public.notification_preferences where user_id = member_id), 'Saving Comments reset another category';
  perform set_config('request.jwt.claim.sub', member_id::text, true);
end $$;

set local role authenticated;
do $$
declare affected integer; rejected boolean := false;
begin
  assert (select count(*) = 1 from public.notification_preferences), 'Can read another account preferences';
  update public.notification_preferences set friend_requests_enabled = false, reactions_enabled = false, activity_enabled = false
    where user_id = current_setting('test.preferences_member_id')::uuid;
  get diagnostics affected = row_count;
  assert affected = 1, 'Owner cannot opt out';
  update public.notification_preferences set comments_enabled = false
    where user_id = current_setting('test.preferences_other_id')::uuid;
  get diagnostics affected = row_count;
  assert affected = 0, 'Can change another account preferences';
  begin
    insert into public.notification_preferences(user_id, reactions_enabled)
      values (current_setting('test.preferences_other_id')::uuid, false)
      on conflict (user_id) do update set reactions_enabled = false;
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'Can upsert another account preferences';
end $$;
reset role;
select 'PASS: default-on rows, independent opt-outs, and account ownership' as result;
