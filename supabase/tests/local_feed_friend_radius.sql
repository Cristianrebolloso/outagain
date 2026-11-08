-- Synthetic fixtures only. The rollback also prevents queued pushes from sending.
begin;
insert into auth.users(id,email,raw_user_meta_data) select
  ('a0cb0000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'outagain_local_friend_test_'||i||'@example.invalid','{}'::jsonb
from generate_series(1,3) i;
update public.profiles set username='oa_local_friend_'||right(id::text,1),display_name='Local test'
where id::text like 'a0cb0000-%';
insert into public.friendships(user_id,friend_id,status) values
('a0cb0000-0000-4000-8000-000000000001','a0cb0000-0000-4000-8000-000000000002','accepted'),
('a0cb0000-0000-4000-8000-000000000002','a0cb0000-0000-4000-8000-000000000003','accepted');
insert into public.posts(id,author_id,drink_name,caption,latitude,longitude,is_shared_locally,image_path,created_at) values
('b0cb0000-0000-4000-8000-000000000001','a0cb0000-0000-4000-8000-000000000002','Water','Nearby friend',30.12,-97.12,true,'test/local-friend.jpg',now()-interval '2 minutes'),
('b0cb0000-0000-4000-8000-000000000002','a0cb0000-0000-4000-8000-000000000002','Water','Far friend',32,-97,true,'test/far-friend.jpg',now()-interval '3 minutes'),
('b0cb0000-0000-4000-8000-000000000003','a0cb0000-0000-4000-8000-000000000002','Water','Private friend',30.12,-97.12,false,'test/private-friend.jpg',now()-interval '4 minutes'),
('b0cb0000-0000-4000-8000-000000000004','a0cb0000-0000-4000-8000-000000000003','Water','Nearby stranger',30.12,-97.12,true,'test/local-stranger.jpg',now()-interval '5 minutes'),
('b0cb0000-0000-4000-8000-000000000005','a0cb0000-0000-4000-8000-000000000003','Water','Private stranger',30.12,-97.12,false,'test/private-stranger.jpg',now()-interval '6 minutes');
select set_config('request.jwt.claim.sub','a0cb0000-0000-4000-8000-000000000001',true);
set local role authenticated;
select public.update_discovery_context('America/Chicago',30.12,-97.12);
do $$ begin
  assert (select count(*)=2 from public.local_feed_posts(null,null,51) where id::text like 'b0cb0000-%'), 'Local must contain only the nearby opted-in friend and stranger';
  assert (select exists(select 1 from public.local_feed_posts(null,null,51) where id='b0cb0000-0000-4000-8000-000000000001')), 'Nearby friend must appear in Local';
  assert (select count(*)=3 from public.posts where author_id='a0cb0000-0000-4000-8000-000000000002'), 'Sharing to Local must preserve all normal friend reads';
  assert (select not exists(select 1 from public.local_feed_posts(null,null,51) where id in ('b0cb0000-0000-4000-8000-000000000002','b0cb0000-0000-4000-8000-000000000003'))), 'Far or friends-only posts cannot enable Local';
  assert private.can_read_local_post('a0cb0000-0000-4000-8000-000000000002',30.12+degrees((34.99*1609.344)/6371000.0),-97.12,now()), 'Friend just inside 35 miles must qualify';
  assert not private.can_read_local_post('a0cb0000-0000-4000-8000-000000000002',30.12+degrees((35.01*1609.344)/6371000.0),-97.12,now()), 'Friendship cannot override the 35-mile boundary';
  assert (select count(*)=1 from public.posts where author_id='a0cb0000-0000-4000-8000-000000000003'), 'Local access must not expose the same author''s private posts';
  assert (select count(id)=0 from public.profiles where id='a0cb0000-0000-4000-8000-000000000003'), 'Local access must not unlock a nonfriend''s full profile row';
  assert (select count(*)=0 from public.friends_for_profile('a0cb0000-0000-4000-8000-000000000003')), 'Local access must not unlock a nonfriend''s friends list';
end $$;
reset role;
-- Once the qualifying posts expire, even an accepted friend must not keep Local available.
update public.posts set created_at=now()-interval '49 hours'
where id in ('b0cb0000-0000-4000-8000-000000000001','b0cb0000-0000-4000-8000-000000000004');
set local role authenticated;
do $$ begin
  assert (select count(*)=0 from public.local_feed_posts(null,null,51) where id::text like 'b0cb0000-%'), 'Expired Local posts must leave no eligible results';
end $$;
reset role;
select 'PASS: nearby friends in both audiences; private/far friends excluded; 35-mile boundary and expiry; nonfriend profile, posts and friends list remain private' as result;
rollback;
