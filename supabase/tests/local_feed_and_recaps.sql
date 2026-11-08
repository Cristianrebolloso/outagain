-- Execute after the migration inside BEGIN/ROLLBACK. All identities are synthetic;
-- pg_net dispatches only after commit, so these tests cannot send real pushes.
insert into auth.users(id,email,raw_user_meta_data) select
  ('a0ca0000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'outagain_discovery_test_'||i||'@example.invalid','{}'::jsonb from generate_series(1,6) i;
update public.profiles set username='oa_discovery_'||right(id::text,1),display_name='Discovery test'
where id::text like 'a0ca0000-%';
insert into public.friendships(user_id,friend_id,status) values
('a0ca0000-0000-4000-8000-000000000001','a0ca0000-0000-4000-8000-000000000004','accepted'),
('a0ca0000-0000-4000-8000-000000000005','a0ca0000-0000-4000-8000-000000000001','blocked');
insert into public.posts(id,author_id,drink_name,caption,latitude,longitude,is_shared_locally,image_path,created_at,venue_name,venue_latitude,venue_longitude) values
('b0ca0000-0000-4000-8000-000000000001','a0ca0000-0000-4000-8000-000000000002','Water','Near',30.12345,-97.12345,true,'test/near.jpg',now()-interval '2 minutes','Private place',30.12345,-97.12345),
('b0ca0000-0000-4000-8000-000000000002','a0ca0000-0000-4000-8000-000000000003','Water','Far',32,-97,true,'test/far.jpg',now()-interval '2 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000003','a0ca0000-0000-4000-8000-000000000002','Water','Private',30.12,-97.12,false,'test/private.jpg',now()-interval '3 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000004','a0ca0000-0000-4000-8000-000000000005','Water','Blocked',30.12,-97.12,true,'test/blocked.jpg',now()-interval '4 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000005','a0ca0000-0000-4000-8000-000000000002','Water','Expired',30.12,-97.12,true,'test/expired.jpg',now()-interval '49 hours',null,null,null),
('b0ca0000-0000-4000-8000-000000000006','a0ca0000-0000-4000-8000-000000000002','Water','Tie',30.12,-97.12,true,'test/tie.jpg',now()-interval '2 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000007','a0ca0000-0000-4000-8000-000000000003','Water','Inside 35 miles',30.61,-97.12,true,'test/inside-radius.jpg',now()-interval '5 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000008','a0ca0000-0000-4000-8000-000000000003','Water','Outside 35 miles',30.63,-97.12,true,'test/outside-radius.jpg',now()-interval '5 minutes',null,null,null),
('b0ca0000-0000-4000-8000-000000000009','a0ca0000-0000-4000-8000-000000000003','Water','Downtown Dallas',32.78,-96.80,true,'test/dallas.jpg',now()-interval '6 minutes',null,null,null);
insert into public.posts(author_id,drink_name,caption,latitude,longitude,is_shared_locally,image_path,created_at) values
('a0ca0000-0000-4000-8000-000000000002','Water','Future',30.12,-97.12,true,'test/future.jpg',now()+interval '1 day');
select set_config('request.jwt.claim.sub','a0ca0000-0000-4000-8000-000000000001',true);
set local role authenticated;
select public.update_discovery_context('America/Chicago',30.12,-97.12);
do $$
declare rejected boolean:=false; count_read integer;
begin
  assert (select count(*)=3 from public.local_feed_posts(null,null,25)), 'Local visibility or radius incorrect';
  assert (select count(*)=3 from public.posts where id::text like 'b0ca0000-%'), 'Direct REST bypasses audience';
  assert (select exists(select 1 from public.local_feed_posts(null,null,25) where id='b0ca0000-0000-4000-8000-000000000007')), 'Post beyond fifteen miles but within thirty-five is missing';
  assert (select not exists(select 1 from public.local_feed_posts(null,null,25) where id='b0ca0000-0000-4000-8000-000000000008')), 'Post beyond thirty-five miles is visible';
  assert private.can_read_local_post('a0ca0000-0000-4000-8000-000000000003',30.12+degrees((34.99*1609.344)/6371000.0),-97.12,now()), 'Just inside thirty-five miles is excluded';
  assert not private.can_read_local_post('a0ca0000-0000-4000-8000-000000000003',30.12+degrees((35.01*1609.344)/6371000.0),-97.12,now()), 'Just outside thirty-five miles is included';
  assert (select latitude=30.12 and longitude=-97.12 and venue_name is null and venue_latitude is null from public.posts where id='b0ca0000-0000-4000-8000-000000000001'), 'Local location not coarsened';
  assert (select id='b0ca0000-0000-4000-8000-000000000001' from public.local_feed_posts(now()-interval '2 minutes','b0ca0000-0000-4000-8000-000000000006',1)), 'Cursor skips equal-timestamp posts';
  insert into public.comments(id,post_id,author_id,body) values('c0ca0000-0000-4000-8000-000000000001','b0ca0000-0000-4000-8000-000000000001',auth.uid(),'Test');
  insert into public.reactions(post_id,user_id,kind) values('b0ca0000-0000-4000-8000-000000000001',auth.uid(),'cheers');
  insert into public.comment_likes(comment_id,user_id) values('c0ca0000-0000-4000-8000-000000000001',auth.uid());
  assert (select cheers_count=1 and comment_count=1 from public.post_engagement_counts(array['b0ca0000-0000-4000-8000-000000000001'::uuid])), 'Local engagement unavailable';
  perform public.submit_content_report('post','b0ca0000-0000-4000-8000-000000000001',null,null,'Test only');
  begin
    insert into public.comments(post_id,author_id,body) values('b0ca0000-0000-4000-8000-000000000003',auth.uid(),'Forbidden');
  exception when insufficient_privilege then rejected:=true;
  end;
  assert rejected,'Can comment on invisible private post';
  rejected:=false;
  begin
    perform public.submit_content_report('post','b0ca0000-0000-4000-8000-000000000003',null,null,'Forbidden');
  exception when insufficient_privilege then rejected:=true;
  end;
  assert rejected,'Can report invisible private post';
  -- Representative Plano and north Frisco locations must include downtown Dallas.
  perform public.update_discovery_context('America/Chicago',33.02,-96.70);
  assert (select exists(select 1 from public.local_feed_posts(null,null,25) where id='b0ca0000-0000-4000-8000-000000000009')), 'Downtown Dallas missing from Plano';
  perform public.update_discovery_context('America/Chicago',33.22,-96.84);
  assert (select exists(select 1 from public.local_feed_posts(null,null,25) where id='b0ca0000-0000-4000-8000-000000000009')), 'Downtown Dallas missing from north Frisco';
  perform public.update_discovery_context('America/Chicago',32,-97);
  assert (select count(*)=1 from public.local_feed_posts(null,null,25)), 'Moving location leaves old area visible';
end $$;
reset role;
update private.discovery_context set location_updated_at=now()-interval '25 hours' where user_id='a0ca0000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ begin assert (select count(*)=0 from public.local_feed_posts(null,null,25)), 'Stale location grants access'; end $$;
reset role;
-- Three photos by a friend, zero by the recipient, in the last completed cycle.
insert into public.posts(id,author_id,drink_name,caption,image_path,created_at,tagged_user_ids)
select ('b0ca0000-0000-4000-8000-'||lpad((10+i)::text,12,'0'))::uuid,
'a0ca0000-0000-4000-8000-000000000004','Water','Last night','test/recap.jpg',
date_trunc('day',now())-interval '1 day'+interval '18 hours'+i*interval '1 minute',
case when i=1 then array['a0ca0000-0000-4000-8000-000000000001'::uuid] else '{}'::uuid[] end from generate_series(1,3) i;
insert into public.night_groups(id,creator_id,member_ids,created_at) values(
'd0ca0000-0000-4000-8000-000000000001','a0ca0000-0000-4000-8000-000000000004',
array['a0ca0000-0000-4000-8000-000000000001'::uuid,'a0ca0000-0000-4000-8000-000000000004'::uuid],date_trunc('day',now())-interval '1 day'+interval '17 hours');
update private.discovery_context set time_zone='UTC',last_opened_at=date_trunc('day',now())-interval '1 hour',recap_viewed_through=null;
set local role authenticated;
do $$ begin
  assert (select count(*)=3 from public.night_recap_posts(date_trunc('day',now())-interval '1 day'+interval '7 hours',date_trunc('day',now())+interval '7 hours','d0ca0000-0000-4000-8000-000000000001')), 'Nonposter cannot read group recap';
end $$;
reset role;
do $$
declare end_at timestamptz:=date_trunc('day',now())+interval '7 hours';
begin
  assert (select count(*)=1 from public.notifications where user_id='a0ca0000-0000-4000-8000-000000000001' and post_id='b0ca0000-0000-4000-8000-000000000011'), 'Tagged user gets duplicate friend-post alert';
  assert private.enqueue_night_recaps(end_at+interval '3 hours')=0,'Recap before 11am';
  assert private.enqueue_night_recaps(end_at+interval '4 hours')=1,'Nonposter recap missing';
  assert private.enqueue_night_recaps(end_at+interval '4 hours 15 minutes')=0,'Duplicate recap';
  assert (select night_group_id='d0ca0000-0000-4000-8000-000000000001' and night_end=end_at from public.notifications where kind='nightRecap' and user_id='a0ca0000-0000-4000-8000-000000000001'), 'Recap routing missing';
  delete from private.night_recap_deliveries where user_id='a0ca0000-0000-4000-8000-000000000001';
  insert into public.notification_preferences(user_id,recaps_enabled) values('a0ca0000-0000-4000-8000-000000000001',false);
  assert private.enqueue_night_recaps(end_at+interval '4 hours')=0,'Recap opt-out ignored';
  update public.notification_preferences set recaps_enabled=true where user_id='a0ca0000-0000-4000-8000-000000000001';
  update private.discovery_context set recap_viewed_through=end_at where user_id='a0ca0000-0000-4000-8000-000000000001';
  assert private.enqueue_night_recaps(end_at+interval '4 hours')=0,'Viewed recap repeated';
  update private.discovery_context set recap_viewed_through=null,last_opened_at=end_at+interval '1 minute' where user_id='a0ca0000-0000-4000-8000-000000000001';
  assert private.enqueue_night_recaps(end_at+interval '4 hours')=0,'Already active user nudged';
end $$;
