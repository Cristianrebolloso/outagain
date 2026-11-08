-- Run inside BEGIN/ROLLBACK. pg_net only dispatches committed requests;
-- every row and queued HTTP request created here is rolled back.
do $$
declare
  admin_id uuid;
  member_id uuid;
  member_name text;
  other_id uuid;
  in_app_id uuid := gen_random_uuid();
  push_id uuid := gen_random_uuid();
  both_id uuid := gen_random_uuid();
  expected integer;
  actual integer;
  before_count integer;
  rejected boolean;
begin
  select p.id into admin_id from public.profiles p where public.is_app_admin(p.id) limit 1;
  select p.id, p.username into member_id, member_name from public.profiles p
    where not coalesce(p.is_banned, false) and p.id <> admin_id and p.username is not null
      and exists (select 1 from public.devices d where d.user_id = p.id) limit 1;
  select p.id into other_id from public.profiles p where p.id not in (admin_id, member_id) limit 1;
  assert admin_id is not null and member_id is not null and other_id is not null, 'Test accounts unavailable';
  perform set_config('test.member_id', member_id::text, true);
  perform set_config('test.other_id', other_id::text, true);

  assert not has_function_privilege('anon', 'public.admin_publish_announcement(uuid,text,text,text,text[],text)', 'EXECUTE'), 'Anonymous publish allowed';
  perform set_config('request.jwt.claim.sub', member_id::text, true);
  rejected := false;
  begin
    perform public.admin_publish_announcement(gen_random_uuid(), 'QA', 'Not sent', 'all', '{}', 'push');
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'Non-admin publish allowed';
  assert (select count(*) = 0 from public.admin_announcement_history()), 'Non-admin can read history';

  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  select count(*) into before_count from public.notifications;
  perform public.admin_publish_announcement(in_app_id, 'QA in-app', 'Not sent', 'selected', array[member_name], 'in_app');
  assert (select count(*) = before_count from public.notifications), 'In-app send queued a push';
  -- Separate API sends have different transaction times. Model that here
  -- because all test calls deliberately share one rollback transaction.
  update public.app_announcements set created_at = now() - interval '1 second' where id = in_app_id;

  insert into public.notification_preferences(user_id, announcements_enabled) values (member_id, false)
    on conflict (user_id) do update set announcements_enabled = false;
  select count(*)::integer into expected from public.profiles p
    left join public.notification_preferences pref on pref.user_id = p.id
    where not coalesce(p.is_banned, false) and nullif(btrim(coalesce(p.username, '')), '') is not null
      and coalesce(pref.announcements_enabled, true)
      and exists (select 1 from public.devices d where d.user_id = p.id);
  perform public.admin_publish_announcement(push_id, 'QA push', 'Not sent', 'all', '{}', 'push');
  select count(*) into actual from public.notifications n where n.announcement_id = push_id;
  assert actual = expected, 'All-audience fan-out count is wrong';
  assert not exists (select 1 from public.notifications n where n.announcement_id = push_id and n.user_id = member_id), 'Opted-out user targeted';
  assert (select a.is_active from public.app_announcements a where a.id = in_app_id), 'Push-only send deactivated pop-up';
  assert (select a.push_recipient_count = expected from public.app_announcements a where a.id = push_id), 'Queued count is wrong';
  assert (select count(*) = expected from public.notifications n join public.push_attempts p on p.notification_id = n.id where n.announcement_id = push_id), 'Existing push trigger did not run';
  perform public.admin_publish_announcement(push_id, 'QA push', 'Not sent', 'all', '{}', 'push');
  assert (select count(*) = expected from public.notifications n where n.announcement_id = push_id), 'Retry duplicated pushes';

  perform set_config('request.jwt.claim.sub', member_id::text, true);
  assert not exists (select 1 from public.unseen_app_announcements() a where a.id = push_id), 'Push-only appeared as pop-up';
  perform set_config('request.jwt.claim.sub', admin_id::text, true);
  update public.notification_preferences set announcements_enabled = true where user_id = member_id;
  perform public.admin_publish_announcement(both_id, 'QA both', 'Not sent', 'selected', array['@' || upper(member_name), member_name], 'both');
  assert (select count(*) = 1 from public.notifications n where n.announcement_id = both_id and n.user_id = member_id), 'Selected send or duplicate-username normalization failed';
  assert not (select a.is_active from public.app_announcements a where a.id = in_app_id), 'Both did not replace matching pop-up';
  assert exists (select 1 from public.admin_announcement_history(20) h where h.announcement_id = both_id and h.delivery = 'both' and h.push_recipient_count = 1), 'History missing channel or count';
  perform set_config('request.jwt.claim.sub', member_id::text, true);
  assert exists (select 1 from public.unseen_app_announcements() a where a.id = both_id), 'Both missing its pop-up';
  perform set_config('request.jwt.claim.sub', admin_id::text, true);

  -- Delivery receipts survive clearing the corresponding Activity item.
  delete from public.notifications where announcement_id = both_id;
  assert exists (select 1 from public.push_attempts p where p.announcement_id = both_id), 'Clearing Activity lost broadcast receipt';

  -- Verified-only fan-out includes exactly the eligible verified accounts.
  if exists (select 1 from public.profiles p where p.is_verified and not coalesce(p.is_banned, false) and p.username is not null) then
    both_id := gen_random_uuid();
    select count(*)::integer into expected from public.profiles p
      left join public.notification_preferences pref on pref.user_id = p.id
      where p.is_verified and not coalesce(p.is_banned, false)
        and nullif(btrim(coalesce(p.username, '')), '') is not null
        and coalesce(pref.announcements_enabled, true)
        and exists (select 1 from public.devices d where d.user_id = p.id);
    perform public.admin_publish_announcement(both_id, 'QA verified', 'Not sent', 'verified', '{}', 'push');
    assert (select count(*) = expected from public.notifications n where n.announcement_id = both_id), 'Verified audience mismatch';
  end if;

  rejected := false;
  begin
    perform public.admin_publish_announcement(gen_random_uuid(), repeat('x',101), 'Not sent', 'all', '{}', 'push');
  exception when raise_exception then rejected := true;
  end;
  assert rejected, 'Oversized title accepted';
  rejected := false;
  begin
    perform public.admin_publish_announcement(gen_random_uuid(), 'QA', repeat('x',501), 'all', '{}', 'push');
  exception when raise_exception then rejected := true;
  end;
  assert rejected, 'Oversized body accepted';
  rejected := false;
  begin
    perform public.admin_publish_announcement(gen_random_uuid(), 'QA', 'Not sent', 'selected', array['qa_missing_15d6a9'], 'push');
  exception when raise_exception then rejected := true;
  end;
  assert rejected, 'Unknown username accepted';
end;
$$;

-- Exercise real RLS with the authenticated role, not the privileged SQL owner.
set local role authenticated;
do $$ begin perform set_config('request.jwt.claim.sub', current_setting('test.member_id'), true); end $$;
do $$
declare rejected boolean := false;
begin
  assert not exists (select 1 from public.notification_preferences where user_id <> auth.uid()), 'Can read another preference';
  update public.notification_preferences set announcements_enabled = false where user_id = auth.uid();
  assert exists (select 1 from public.notification_preferences where user_id = auth.uid() and not announcements_enabled), 'Own opt-out did not persist';
  begin
    insert into public.notification_preferences(user_id, announcements_enabled)
    values (current_setting('test.other_id')::uuid, false)
    on conflict (user_id) do update set announcements_enabled = false;
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'Can change another account preference';
  rejected := false;
  begin
    insert into public.notifications(user_id, kind, title, detail)
    values (auth.uid(), 'announcement', 'Fake admin', 'Not sent');
  exception when insufficient_privilege then rejected := true;
  end;
  assert rejected, 'Regular client can forge announcement';
end;
$$;
reset role;

select 'All announcement database checks passed; transaction will roll back.' as result;
