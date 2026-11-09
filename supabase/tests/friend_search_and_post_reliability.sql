-- Synthetic identities; rollback prevents pg_net notifications from dispatching.
begin;
set local statement_timeout='20s';
do $$ begin
  assert not has_function_privilege('anon','public.auth_user_email_hash(uuid)','execute'), 'Anonymous users cannot fetch account email hashes';
  assert not has_function_privilege('authenticated','public.auth_user_email_hash(uuid)','execute'), 'Signed-in users cannot fetch account email hashes';
  assert has_function_privilege('service_role','public.auth_user_email_hash(uuid)','execute'), 'Server moderation retains email hash access';
end $$;
insert into auth.users(id,email,raw_user_meta_data)
select ('a0cc0000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'qa_reliability_'||i||'@example.invalid','{}'::jsonb from generate_series(1,6) i;
update public.profiles set username=case right(id::text,1)
  when '1' then 'qz_viewer' when '2' then 'qz_alex' when '3' then 'qzxalex'
  when '4' then 'qz_blocked' when '5' then 'qz_banned' else 'qz_stranger' end,
  display_name=case right(id::text,1) when '2' then 'Alex Morgan' else 'Reliability fixture' end
where id::text like 'a0cc0000-%';
update public.profiles set is_banned=true where id='a0cc0000-0000-4000-8000-000000000005';
do $$ begin
  assert public.is_profile_banned('a0cc0000-0000-4000-8000-000000000005'), 'Banned account must remain blocked';
  assert not public.is_profile_banned('a0cc0000-0000-4000-8000-000000000001'), 'One ban must not block unrelated accounts';
end $$;
insert into public.friendships(user_id,friend_id,status) values
('a0cc0000-0000-4000-8000-000000000004','a0cc0000-0000-4000-8000-000000000001','blocked');
insert into public.posts(id,author_id,drink_name,image_path,caption) values
('b0cc0000-0000-4000-8000-000000000001','a0cc0000-0000-4000-8000-000000000002','','test/private.jpg','Private');
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare rejected boolean:=false;
begin
  assert (select count(*)=3 from public.search_profiles('qz')), 'Two-character search, self/block/ban filtering';
  assert (select count(*)=1 from public.search_profiles('  @QZ_AL  ')), 'Handle normalization or literal underscore';
  assert (select count(*)=1 from public.search_profiles('Alex Morgan')), 'Full name search';
  assert (select count(*)=1 from public.search_profiles(E'  ALEX   \t MORGAN  ')), 'Repeated whitespace in a pasted name';
  assert exists(select 1 from public.search_profiles('morgan') where id='a0cc0000-0000-4000-8000-000000000002'), 'Last name search';
  assert (select count(*)=0 from public.search_profiles('x')), 'Short search must stay empty';
  assert (select count(*)=0 from public.search_profiles('%')), 'Search wildcard must not enumerate users';
  assert (select count(*)=1 from public.profiles_by_exact_usernames(array['qz_al'])), 'Legacy prefix search treats underscores literally';
  assert (select count(*)=4 from public.profiles_by_exact_usernames(array['qz'])),'Legacy two-character search includes self';
  assert (select count(*)=0 from public.posts where id='b0cc0000-0000-4000-8000-000000000001'), 'Search must not expose private posts';
  insert into public.friendships(id,user_id,friend_id,status) values
    ('c0cc0000-0000-4000-8000-000000000001',auth.uid(),'a0cc0000-0000-4000-8000-000000000002','pending');
  assert exists(select 1 from public.profiles where id='a0cc0000-0000-4000-8000-000000000002'), 'Pending recipient profile must hydrate for sender';
  begin
    update public.friendships set status='accepted' where id='c0cc0000-0000-4000-8000-000000000001';
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected, 'Sender cannot accept own request';
  rejected:=false;
  begin
    insert into public.friendships(user_id,friend_id,status) values(auth.uid(),'a0cc0000-0000-4000-8000-000000000006','accepted');
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected, 'Direct insert cannot skip recipient consent';
  rejected:=false;
  begin
    insert into public.friendships(user_id,friend_id,status) values(auth.uid(),'a0cc0000-0000-4000-8000-000000000004','pending');
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected, 'Blocked account cannot send another request';
  delete from public.friendships where user_id='a0cc0000-0000-4000-8000-000000000004' and friend_id=auth.uid();
  assert exists(select 1 from public.friendships where user_id='a0cc0000-0000-4000-8000-000000000004' and status='blocked'), 'Blocked person cannot remove another account block';
end $$;
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000002',true);
do $$ begin
  assert exists(select 1 from public.profiles where id='a0cc0000-0000-4000-8000-000000000001'), 'Pending sender profile must hydrate for recipient';
end $$;
update public.friendships set status='accepted' where id='c0cc0000-0000-4000-8000-000000000001';
-- Retrying after a lost acceptance response must not send another alert.
update public.friendships set status='accepted' where id='c0cc0000-0000-4000-8000-000000000001';
do $$ begin assert public.is_friend(auth.uid(),'a0cc0000-0000-4000-8000-000000000001'), 'Recipient acceptance must create friendship'; end $$;
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000001',true);
do $$ declare rejected boolean:=false;
begin
  assert exists(select 1 from public.posts where id='b0cc0000-0000-4000-8000-000000000001'), 'Accepted friend must see posts';
  update public.friendships set status='pending' where id='c0cc0000-0000-4000-8000-000000000001';
  assert public.is_friend(auth.uid(),'a0cc0000-0000-4000-8000-000000000002'), 'Stale retry must preserve accepted friendship';
  assert (select count(*)=1 from public.notifications where user_id=auth.uid() and actor_id='a0cc0000-0000-4000-8000-000000000002' and kind='friendAccepted'), 'Acceptance retries must not duplicate notifications';
  insert into public.posts(id,author_id,drink_name,caption,image_path,tagged_user_ids) values
    ('b0cc0000-0000-4000-8000-000000000002',auth.uid(),'','','test/photo-only.jpg',array['a0cc0000-0000-4000-8000-000000000002'::uuid]);
  insert into public.posts(id,author_id,drink_name,caption,image_path,tagged_user_ids) values
    ('b0cc0000-0000-4000-8000-000000000002',auth.uid(),'','','test/photo-only.jpg',array['a0cc0000-0000-4000-8000-000000000002'::uuid])
    on conflict(id) do nothing;
  assert (select count(*)=1 from public.posts where id='b0cc0000-0000-4000-8000-000000000002'), 'Stable post ID prevents duplicate inserts';
  begin
    insert into public.posts(author_id,drink_name,image_path,tagged_user_ids) values(auth.uid(),'','test/invalid-tag.jpg',array['a0cc0000-0000-4000-8000-000000000006'::uuid]);
  exception when check_violation then rejected:=true; end;
  assert rejected, 'Only accepted friends can be tagged';
  rejected:=false;
  begin
    insert into public.posts(author_id,drink_name,image_path) values('a0cc0000-0000-4000-8000-000000000006','','test/forged.jpg');
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected, 'Cannot publish as another person';
end $$;
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000002',true);
insert into public.comments(id,post_id,author_id,body) values
('d0cc0000-0000-4000-8000-000000000001','b0cc0000-0000-4000-8000-000000000002',auth.uid(),'Test comment');
insert into public.reactions(post_id,user_id,kind) values('b0cc0000-0000-4000-8000-000000000002',auth.uid(),'cheers');
do $$ begin
  assert (select count(*)=1 from public.notifications where post_id='b0cc0000-0000-4000-8000-000000000002' and kind='tagged'), 'Retry must not duplicate tag notifications';
end $$;
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000006',true);
do $$ declare rejected boolean:=false;
begin
  assert not exists(select 1 from public.posts where id='b0cc0000-0000-4000-8000-000000000002'), 'Stranger cannot read private post';
  begin perform public.delete_own_post('b0cc0000-0000-4000-8000-000000000002');
  exception when insufficient_privilege then rejected:=true; end;
  assert rejected,'Stranger cannot delete post';
end $$;
select set_config('request.jwt.claim.sub','a0cc0000-0000-4000-8000-000000000001',true);
select public.delete_own_post('b0cc0000-0000-4000-8000-000000000002');
reset role;
do $$ begin
  assert not exists(select 1 from public.posts where id='b0cc0000-0000-4000-8000-000000000002'), 'Owner deletion';
  assert not exists(select 1 from public.comments where post_id='b0cc0000-0000-4000-8000-000000000002'), 'Comment cleanup';
  assert not exists(select 1 from public.reactions where post_id='b0cc0000-0000-4000-8000-000000000002'), 'Reaction cleanup';
  assert not exists(select 1 from public.notifications where post_id='b0cc0000-0000-4000-8000-000000000002'), 'Notification cleanup';
end $$;
select 'PASS: username/name search, blocks/bans, request consent, photo-only posts, idempotency, tags, visibility, engagement, deletion' as result;
rollback;
