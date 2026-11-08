create extension if not exists pgcrypto;

-- The app already depends on night_groups at runtime. Keep the table creation
-- in migrations so App Review/demo data and fresh environments are reproducible.
create table if not exists public.night_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  creator_id uuid not null references auth.users (id) on delete cascade,
  member_ids uuid[] not null default '{}',
  created_at timestamptz not null default timezone('utc', now())
);

alter table public.night_groups enable row level security;

drop policy if exists "members_select" on public.night_groups;
create policy "members_select"
on public.night_groups
for select
to authenticated
using (auth.uid() = any(member_ids));

drop policy if exists "creator_insert" on public.night_groups;
create policy "creator_insert"
on public.night_groups
for insert
to authenticated
with check (auth.uid() = creator_id and auth.uid() = any(member_ids));

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

drop policy if exists "creator_delete" on public.night_groups;
create policy "creator_delete"
on public.night_groups
for delete
to authenticated
using (auth.uid() = creator_id);

create index if not exists night_groups_created_at_idx
  on public.night_groups (created_at desc);

create or replace function public.ensure_app_review_demo_profile(
  desired_id uuid,
  seed_email text,
  seed_username text,
  seed_display_name text
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  resolved_id uuid;
begin
  select p.id
    into resolved_id
  from public.profiles p
  where p.username = seed_username
  limit 1;

  if resolved_id is null then
    select u.id
      into resolved_id
    from auth.users u
    where lower(u.email) = lower(seed_email)
    limit 1;
  end if;

  if resolved_id is null then
    resolved_id := desired_id;

    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      created_at,
      updated_at,
      raw_app_meta_data,
      raw_user_meta_data,
      is_super_admin,
      is_sso_user,
      is_anonymous
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      resolved_id,
      'authenticated',
      'authenticated',
      lower(seed_email),
      null,
      now(),
      now(),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('name', seed_display_name),
      false,
      false,
      false
    )
    on conflict (id) do update
      set updated_at = excluded.updated_at;
  end if;

  if not exists (
    select 1
    from auth.identities i
    where i.user_id = resolved_id
      and i.provider = 'email'
  ) then
    insert into auth.identities (
      id,
      user_id,
      provider_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    )
    values (
      gen_random_uuid(),
      resolved_id,
      resolved_id::text,
      jsonb_build_object(
        'sub', resolved_id::text,
        'email', lower(seed_email),
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      null,
      now(),
      now()
    )
    on conflict (provider_id, provider) do update
      set identity_data = excluded.identity_data,
          updated_at = excluded.updated_at;
  end if;

  insert into public.profiles (
    id,
    username,
    display_name,
    avatar_path,
    normalized_email_hash,
    custom_drinks,
    deleted_drink_names,
    drink_order_names
  )
  values (
    resolved_id,
    seed_username,
    seed_display_name,
    null,
    null,
    '[]'::jsonb,
    '{}'::text[],
    '{}'::text[]
  )
  on conflict (id) do update
    set username = excluded.username,
        display_name = excluded.display_name,
        normalized_email_hash = coalesce(public.profiles.normalized_email_hash, excluded.normalized_email_hash),
        updated_at = timezone('utc', now());

  return resolved_id;
end;
$$;

do $$
declare
  review_id uuid;
  review_username text := 'appreview';
  test3_id uuid;
  riley_id uuid;
  morgan_id uuid;
  nia_id uuid;
  sam_id uuid;
  all_demo_ids uuid[];
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
  base_time timestamptz := now();
begin
  select u.id
    into review_id
  from auth.users u
  where lower(u.email) = 'apple@test.com'
  limit 1;

  if review_id is null then
    review_id := '5cfc9de0-685e-4a5f-9aac-e047070d2e5e'::uuid;

    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      created_at,
      updated_at,
      raw_app_meta_data,
      raw_user_meta_data,
      is_super_admin,
      is_sso_user,
      is_anonymous
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      review_id,
      'authenticated',
      'authenticated',
      'apple@test.com',
      null,
      now(),
      now(),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"name":"Apple Review"}'::jsonb,
      false,
      false,
      false
    )
    on conflict (id) do nothing;
  end if;

  update auth.users
  set email_confirmed_at = coalesce(email_confirmed_at, now()),
      updated_at = now(),
      raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"provider":"email","providers":["email"]}'::jsonb
  where id = review_id;

  if exists (
    select 1
    from public.profiles p
    where p.username = review_username
      and p.id <> review_id
  ) then
    review_username := 'appletest';
  end if;

  if exists (
    select 1
    from public.profiles p
    where p.username = review_username
      and p.id <> review_id
  ) then
    review_username := 'reviewtest';
  end if;

  insert into public.profiles (
    id,
    username,
    display_name,
    avatar_path,
    normalized_email_hash,
    custom_drinks,
    deleted_drink_names,
    drink_order_names
  )
  values (
    review_id,
    review_username,
    'Apple Review',
    null,
    '623d190e64f92a5c64c94559d02e1021c1de9be2ca31b315cf74628ebc0d1bde',
    '[]'::jsonb,
    '{}'::text[],
    '{}'::text[]
  )
  on conflict (id) do update
    set username = excluded.username,
        display_name = excluded.display_name,
        normalized_email_hash = excluded.normalized_email_hash,
        updated_at = timezone('utc', now());

  test3_id := public.ensure_app_review_demo_profile(
    '51d53a11-8c3b-4af5-a6c6-000000000003'::uuid,
    'outagain.appreview+test3account@example.com',
    'test3account',
    'Test Three'
  );

  riley_id := public.ensure_app_review_demo_profile(
    '51d53a11-8c3b-4af5-a6c6-000000000004'::uuid,
    'outagain.appreview+riley@example.com',
    'rileyout',
    'Riley Out'
  );

  morgan_id := public.ensure_app_review_demo_profile(
    '51d53a11-8c3b-4af5-a6c6-000000000005'::uuid,
    'outagain.appreview+morgan@example.com',
    'morganlate',
    'Morgan Late'
  );

  nia_id := public.ensure_app_review_demo_profile(
    '51d53a11-8c3b-4af5-a6c6-000000000006'::uuid,
    'outagain.appreview+nia@example.com',
    'niainvite',
    'Nia Invite'
  );

  sam_id := public.ensure_app_review_demo_profile(
    '51d53a11-8c3b-4af5-a6c6-000000000007'::uuid,
    'outagain.appreview+sam@example.com',
    'samnew',
    'Sam New'
  );

  all_demo_ids := array[review_id, test3_id, riley_id, morgan_id, nia_id, sam_id];

  delete from public.notifications
  where id = any(seed_notification_ids)
     or (user_id = review_id and actor_id = any(all_demo_ids))
     or (actor_id = review_id and user_id = any(all_demo_ids));

  delete from public.night_groups
  where id = seed_group_id;

  delete from public.friendships
  where user_id = any(all_demo_ids)
    and friend_id = any(all_demo_ids);

  delete from public.posts
  where id = any(seed_post_ids);

  insert into public.friendships (id, user_id, friend_id, status, created_at)
  values
    ('75000000-0000-4000-8000-000000000001'::uuid, review_id, test3_id, 'accepted', base_time - interval '5 hours'),
    ('75000000-0000-4000-8000-000000000002'::uuid, review_id, riley_id, 'accepted', base_time - interval '4 hours'),
    ('75000000-0000-4000-8000-000000000003'::uuid, review_id, morgan_id, 'accepted', base_time - interval '3 hours'),
    ('75000000-0000-4000-8000-000000000004'::uuid, test3_id, sam_id, 'accepted', base_time - interval '2 hours'),
    ('75000000-0000-4000-8000-000000000005'::uuid, nia_id, review_id, 'pending', base_time - interval '50 minutes');

  insert into public.posts (
    id,
    author_id,
    drink_name,
    drink_subtitle,
    drink_symbol,
    drink_primary_hex,
    drink_secondary_hex,
    venue_name,
    venue_neighborhood,
    venue_city,
    venue_latitude,
    venue_longitude,
    latitude,
    longitude,
    horizontal_accuracy,
    caption,
    image_path,
    tagged_user_ids,
    is_shared_moment,
    created_at
  )
  values
    (
      seed_post_ids[1],
      test3_id,
      'Margarita',
      'Salt rim',
      'sparkles',
      '#B7D06B',
      '#1F2817',
      'Sparrow',
      'River North',
      'Chicago',
      41.8929,
      -87.6315,
      null,
      null,
      null,
      'Venue-tagged demo post. Use this card to test reactions, comments, reporting, and the friend profile menu.',
      null,
      array[review_id, riley_id]::uuid[],
      false,
      base_time - interval '35 minutes'
    ),
    (
      seed_post_ids[2],
      riley_id,
      'Beer',
      'Lager',
      'waterbottle.fill',
      '#D9A441',
      '#2A1A12',
      null,
      null,
      null,
      null,
      null,
      41.8781,
      -87.6298,
      35,
      'City-level night out check-in from Chicago, IL.',
      null,
      array[review_id]::uuid[],
      false,
      base_time - interval '1 hour'
    ),
    (
      seed_post_ids[3],
      morgan_id,
      'Espresso Martini',
      'Second wind',
      'moon.stars.fill',
      '#8C5A3C',
      '#2A1815',
      'Juniper Room',
      'West Loop',
      'Chicago',
      41.8856,
      -87.6482,
      null,
      null,
      null,
      'Group-feed seed post with venue and tags.',
      null,
      array[test3_id, review_id]::uuid[],
      true,
      base_time - interval '1 hour 45 minutes'
    ),
    (
      seed_post_ids[4],
      review_id,
      'Seltzer',
      'No location',
      'bubbles.and.sparkles.fill',
      '#7FB3C7',
      '#17202A',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'App Review demo post with no location attached. Friends can react and comment here.',
      null,
      array[test3_id]::uuid[],
      false,
      base_time - interval '2 hours 15 minutes'
    ),
    (
      seed_post_ids[5],
      test3_id,
      'Wine',
      'Red',
      'wineglass.fill',
      '#964A59',
      '#231518',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'Older direct-friend post for profile grid and pagination checks.',
      null,
      '{}'::uuid[],
      false,
      base_time - interval '5 hours'
    );

  insert into public.comments (
    id,
    post_id,
    author_id,
    body,
    kind,
    image_path,
    reply_to_comment_id,
    mentioned_user_ids,
    created_at
  )
  values
    (
      seed_comment_ids[1],
      seed_post_ids[1],
      review_id,
      'Testing the comment thread from the App Review account.',
      'text',
      null,
      null,
      '{}'::uuid[],
      base_time - interval '25 minutes'
    ),
    (
      seed_comment_ids[2],
      seed_post_ids[1],
      riley_id,
      'Replying so preview comments and notifications are visible.',
      'text',
      null,
      seed_comment_ids[1],
      array[review_id]::uuid[],
      base_time - interval '20 minutes'
    ),
    (
      seed_comment_ids[3],
      seed_post_ids[4],
      test3_id,
      'Looks good from @test3account.',
      'text',
      null,
      null,
      array[review_id]::uuid[],
      base_time - interval '1 hour 55 minutes'
    ),
    (
      seed_comment_ids[4],
      seed_post_ids[3],
      review_id,
      'Opening this group post from the demo account.',
      'text',
      null,
      null,
      '{}'::uuid[],
      base_time - interval '1 hour 20 minutes'
    );

  insert into public.reactions (post_id, user_id, kind, created_at)
  values
    (seed_post_ids[1], review_id, 'cheers', base_time - interval '23 minutes'),
    (seed_post_ids[1], riley_id, 'fire', base_time - interval '18 minutes'),
    (seed_post_ids[2], review_id, 'spark', base_time - interval '45 minutes'),
    (seed_post_ids[4], test3_id, 'cheers', base_time - interval '1 hour 50 minutes'),
    (seed_post_ids[4], riley_id, 'fire', base_time - interval '1 hour 45 minutes'),
    (seed_post_ids[3], review_id, 'cheers', base_time - interval '1 hour 15 minutes')
  on conflict (post_id, user_id, kind) do nothing;

  insert into public.comment_likes (comment_id, user_id, created_at)
  values
    (seed_comment_ids[2], review_id, base_time - interval '19 minutes'),
    (seed_comment_ids[3], review_id, base_time - interval '1 hour 45 minutes')
  on conflict (comment_id, user_id) do nothing;

  insert into public.night_groups (id, name, creator_id, member_ids, created_at)
  values (
    seed_group_id,
    'App Review Night',
    review_id,
    array[review_id, test3_id, riley_id, morgan_id]::uuid[],
    base_time - interval '40 minutes'
  )
  on conflict (id) do update
    set name = excluded.name,
        creator_id = excluded.creator_id,
        member_ids = excluded.member_ids,
        created_at = excluded.created_at;

  insert into public.notifications (
    id,
    user_id,
    actor_id,
    post_id,
    comment_id,
    kind,
    title,
    detail,
    read_at,
    created_at
  )
  values
    (
      seed_notification_ids[1],
      review_id,
      nia_id,
      null,
      null,
      'friendRequest',
      'Nia Invite wants to be friends',
      'Tap to accept or ignore.',
      null,
      base_time - interval '50 minutes'
    ),
    (
      seed_notification_ids[2],
      review_id,
      test3_id,
      seed_post_ids[4],
      seed_comment_ids[3],
      'comment',
      'Test Three commented on your post',
      'Looks good from @test3account.',
      null,
      base_time - interval '1 hour 55 minutes'
    ),
    (
      seed_notification_ids[3],
      review_id,
      riley_id,
      seed_post_ids[4],
      null,
      'reaction',
      'Riley Out liked your post',
      'Fire on your Seltzer.',
      null,
      base_time - interval '1 hour 45 minutes'
    ),
    (
      seed_notification_ids[4],
      review_id,
      test3_id,
      null,
      null,
      'groupAdded',
      'Test Three added you to App Review Night',
      'A demo group feed has been preloaded with friends and posts.',
      null,
      base_time - interval '40 minutes'
    )
  on conflict (id) do update
    set user_id = excluded.user_id,
        actor_id = excluded.actor_id,
        post_id = excluded.post_id,
        comment_id = excluded.comment_id,
        kind = excluded.kind,
        title = excluded.title,
        detail = excluded.detail,
        read_at = excluded.read_at,
        created_at = excluded.created_at;
end;
$$;

drop function if exists public.ensure_app_review_demo_profile(uuid, text, text, text);
