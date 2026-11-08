-- Keep App Review demo content visible even when review takes several days.
--
-- The seeded rows are fixed demo records, but Home/Groups/Tonight UI depends
-- on recent timestamps. The iOS client calls this RPC only for the App Review
-- account before bootstrapping feed data. Real users cannot use it to refresh
-- their own content.

create or replace function public.refresh_app_review_demo_content()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  caller_id uuid := auth.uid();
  base_time timestamptz := now();
  review_id uuid;
  test3_id uuid;
  riley_id uuid;
  morgan_id uuid;
  nia_id uuid;
  sam_id uuid;
  demo_user_ids uuid[];
  seed_post_ids uuid[] := array[
    '71000000-0000-4000-8000-000000000001'::uuid,
    '71000000-0000-4000-8000-000000000002'::uuid,
    '71000000-0000-4000-8000-000000000003'::uuid,
    '71000000-0000-4000-8000-000000000004'::uuid,
    '71000000-0000-4000-8000-000000000005'::uuid
  ];
  seed_comment_ids uuid[] := array[
    '72000000-0000-4000-8000-000000000001'::uuid,
    '72000000-0000-4000-8000-000000000002'::uuid,
    '72000000-0000-4000-8000-000000000003'::uuid,
    '72000000-0000-4000-8000-000000000004'::uuid
  ];
  seed_notification_ids uuid[] := array[
    '73000000-0000-4000-8000-000000000001'::uuid,
    '73000000-0000-4000-8000-000000000002'::uuid,
    '73000000-0000-4000-8000-000000000003'::uuid,
    '73000000-0000-4000-8000-000000000004'::uuid
  ];
  seed_group_id uuid := '74000000-0000-4000-8000-000000000001'::uuid;
begin
  if caller_id is null then
    return;
  end if;

  select p.id
    into review_id
  from public.profiles p
  where p.id = caller_id
    and p.username in ('appreview', 'appletest')
  limit 1;

  if review_id is null then
    select u.id
      into review_id
    from auth.users u
    where u.id = caller_id
      and lower(u.email) = 'apple@test.com'
    limit 1;
  end if;

  if review_id is null then
    return;
  end if;

  select p.id into test3_id from public.profiles p where p.username = 'test3account' limit 1;
  select p.id into riley_id from public.profiles p where p.username = 'rileyout' limit 1;
  select p.id into morgan_id from public.profiles p where p.username = 'morganlate' limit 1;
  select p.id into nia_id from public.profiles p where p.username = 'niainvite' limit 1;
  select p.id into sam_id from public.profiles p where p.username = 'samnew' limit 1;

  demo_user_ids := array_remove(
    array[review_id, test3_id, riley_id, morgan_id, nia_id, sam_id]::uuid[],
    null::uuid
  );

  update public.friendships
  set created_at = case id
    when '75000000-0000-4000-8000-000000000001'::uuid then base_time - interval '5 hours'
    when '75000000-0000-4000-8000-000000000002'::uuid then base_time - interval '4 hours'
    when '75000000-0000-4000-8000-000000000003'::uuid then base_time - interval '3 hours'
    when '75000000-0000-4000-8000-000000000004'::uuid then base_time - interval '2 hours'
    when '75000000-0000-4000-8000-000000000005'::uuid then base_time - interval '50 minutes'
    else created_at
  end
  where id in (
    '75000000-0000-4000-8000-000000000001'::uuid,
    '75000000-0000-4000-8000-000000000002'::uuid,
    '75000000-0000-4000-8000-000000000003'::uuid,
    '75000000-0000-4000-8000-000000000004'::uuid,
    '75000000-0000-4000-8000-000000000005'::uuid
  );

  update public.posts
  set created_at = case id
    when seed_post_ids[1] then base_time - interval '35 minutes'
    when seed_post_ids[2] then base_time - interval '1 hour'
    when seed_post_ids[3] then base_time - interval '1 hour 45 minutes'
    when seed_post_ids[4] then base_time - interval '2 hours 15 minutes'
    when seed_post_ids[5] then base_time - interval '5 hours'
    else created_at
  end
  where id = any(seed_post_ids);

  update public.comments
  set created_at = case id
    when seed_comment_ids[1] then base_time - interval '25 minutes'
    when seed_comment_ids[2] then base_time - interval '20 minutes'
    when seed_comment_ids[3] then base_time - interval '1 hour 55 minutes'
    when seed_comment_ids[4] then base_time - interval '1 hour 20 minutes'
    else created_at
  end
  where id = any(seed_comment_ids);

  update public.reactions
  set created_at = case
    when post_id = seed_post_ids[1] and user_id = review_id then base_time - interval '23 minutes'
    when post_id = seed_post_ids[1] and user_id = riley_id then base_time - interval '18 minutes'
    when post_id = seed_post_ids[2] and user_id = review_id then base_time - interval '45 minutes'
    when post_id = seed_post_ids[4] and user_id = test3_id then base_time - interval '1 hour 50 minutes'
    when post_id = seed_post_ids[4] and user_id = riley_id then base_time - interval '1 hour 45 minutes'
    when post_id = seed_post_ids[3] and user_id = review_id then base_time - interval '1 hour 15 minutes'
    else created_at
  end
  where post_id = any(seed_post_ids)
    and user_id = any(demo_user_ids);

  update public.comment_likes
  set created_at = case
    when comment_id = seed_comment_ids[2] and user_id = review_id then base_time - interval '19 minutes'
    when comment_id = seed_comment_ids[3] and user_id = review_id then base_time - interval '1 hour 45 minutes'
    else created_at
  end
  where comment_id = any(seed_comment_ids)
    and user_id = any(demo_user_ids);

  update public.night_groups
  set created_at = base_time - interval '40 minutes'
  where id = seed_group_id
    and review_id = any(member_ids);

  update public.notifications
  set created_at = case id
    when seed_notification_ids[1] then base_time - interval '50 minutes'
    when seed_notification_ids[2] then base_time - interval '1 hour 55 minutes'
    when seed_notification_ids[3] then base_time - interval '1 hour 45 minutes'
    when seed_notification_ids[4] then base_time - interval '40 minutes'
    else created_at
  end
  where id = any(seed_notification_ids)
    and user_id = review_id;
end;
$$;

grant execute on function public.refresh_app_review_demo_content() to authenticated;
