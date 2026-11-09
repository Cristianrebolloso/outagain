-- All synthetic activity, notifications, and invitations roll back together.
begin;
set local statement_timeout='20s';
do $$ begin
  assert private.night_invite_expiry('2026-11-08 12:59:59+00','America/Chicago')='2026-11-08 13:00:00+00'::timestamptz, 'Before 7am belongs to previous night';
  assert private.night_invite_expiry('2026-11-08 13:00:00+00','America/Chicago')='2026-11-09 13:00:00+00'::timestamptz, 'At 7am starts next night';
  assert private.night_invite_expiry('2026-03-07 18:00:00+00','America/Chicago')='2026-03-08 12:00:00+00'::timestamptz, 'Spring DST expiry uses local 7am';
  assert private.night_invite_expiry('2026-10-31 17:00:00+00','America/Chicago')='2026-11-01 13:00:00+00'::timestamptz, 'Fall DST expiry uses local 7am';
end $$;
insert into auth.users(id,email,raw_user_meta_data)
select ('a0ce0000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'qa_invite_'||i||'@example.invalid','{}'::jsonb from generate_series(1,5) i;
update public.profiles set username='qz_invite_'||right(id::text,1),display_name='Invite Test'
where id::text like 'a0ce0000-%';
insert into public.posts(id,author_id,drink_name,image_path,caption) values
('b0ce0000-0000-4000-8000-000000000001','a0ce0000-0000-4000-8000-000000000001','Beer','test/invite.jpg','Private');
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000001',true);
set local role authenticated;
insert into public.night_groups(id,name,creator_id,member_ids) values
('c0ce0000-0000-4000-8000-000000000001','Tonight',auth.uid(),array[auth.uid()]);
do $$ declare invitation jsonb; failed boolean:=false;
begin
  assert not has_function_privilege('anon','public.create_social_invite(uuid,text)','execute'), 'Anonymous invite creation denied';
  assert not has_function_privilege('anon','public.resolve_social_invite(text)','execute'), 'Anonymous profile resolution denied';
  assert not has_table_privilege('authenticated','private.social_invites','select'), 'Tokens cannot be enumerated';
  invitation := public.create_social_invite(null);
  assert (invitation->>'expires_at')::timestamptz=now()+interval '30 days', 'Friend invite keeps 30-day lifetime';
  perform set_config('qa.friend_code',invitation->>'token',true);
  assert invitation->>'token'=public.create_social_invite(null)->>'token', 'Repeated share reuses active code';
  invitation := public.create_social_invite('c0ce0000-0000-4000-8000-000000000001','America/Chicago');
  perform set_config('qa.group_code',invitation->>'token',true);
  assert invitation->>'group_name'='Tonight', 'Solo group invite is shareable';
  assert (invitation->>'expires_at')::timestamptz<=now()+interval '25 hours', 'Group invite cannot outlive the night';
  begin perform public.create_social_invite('c0ce0000-0000-4000-8000-000000000001','Invalid/TimeZone');
  exception when invalid_parameter_value then failed:=true; end;
  assert failed, 'Invalid timezone rejected';
  failed := false;
  begin perform public.accept_social_invite(current_setting('qa.friend_code'));
  exception when invalid_parameter_value then failed:=true; end;
  assert failed, 'Own invite must not self-friend';
end $$;
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000002',true);
do $$ declare result jsonb; failed boolean:=false;
begin
  result := public.resolve_social_invite(upper(current_setting('qa.group_code')));
  assert result->>'inviter_id'='a0ce0000-0000-4000-8000-000000000001', 'Code resolution';
  assert not public.is_friend(auth.uid(),'a0ce0000-0000-4000-8000-000000000001'), 'Preview never creates friendship';
  assert not exists(select 1 from public.night_groups where id='c0ce0000-0000-4000-8000-000000000001'), 'Preview never joins group';
  result := public.accept_social_invite(current_setting('qa.group_code'));
  assert result->>'friendship_status'='pending', 'Explicit accept sends request, never bypasses recipient consent';
  assert exists(select 1 from public.night_groups where id='c0ce0000-0000-4000-8000-000000000001' and auth.uid()=any(member_ids)), 'Explicit accept joins group';
  assert not exists(select 1 from public.posts where id='b0ce0000-0000-4000-8000-000000000001'), 'Group join does not expose private posts';
  perform public.accept_social_invite(current_setting('qa.group_code'));
  assert (select count(*)=1 from public.friendships where user_id=auth.uid() and friend_id='a0ce0000-0000-4000-8000-000000000001'), 'Retry produces one request';
  assert (select cardinality(member_ids)=2 from public.night_groups where id='c0ce0000-0000-4000-8000-000000000001'), 'Retry does not duplicate group member';
  begin perform public.create_social_invite('c0ce0000-0000-4000-8000-000000000001');
  exception when insufficient_privilege then failed:=true; end;
  assert failed, 'Only creator distributes group invites';
end $$;
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000001',true);
do $$ begin
  assert public.send_friend_request('a0ce0000-0000-4000-8000-000000000002')='accepted', 'Reciprocal explicit request accepts';
  assert public.send_friend_request('a0ce0000-0000-4000-8000-000000000002')='accepted', 'Accepted retry stays accepted';
  assert (select count(*)=1 from public.friendships where (user_id=auth.uid() and friend_id='a0ce0000-0000-4000-8000-000000000002') or (friend_id=auth.uid() and user_id='a0ce0000-0000-4000-8000-000000000002')), 'Reciprocal taps preserve a single pair';
end $$;
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000002',true);
do $$ begin
  assert exists(select 1 from public.posts where id='b0ce0000-0000-4000-8000-000000000001'), 'Accepted friendship grants post visibility';
end $$;
reset role;
insert into public.friendships(user_id,friend_id,status) values
('a0ce0000-0000-4000-8000-000000000001','a0ce0000-0000-4000-8000-000000000003','blocked');
update public.profiles set is_banned=true where id='a0ce0000-0000-4000-8000-000000000004';
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000003',true);
set local role authenticated;
do $$ declare failed boolean:=false;
begin
  begin perform public.accept_social_invite(current_setting('qa.friend_code'));
  exception when invalid_parameter_value then failed:=true; end;
  assert failed, 'Blocked user cannot redeem an invite';
end $$;
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000004',true);
do $$ declare failed boolean:=false;
begin
  begin perform public.resolve_social_invite(current_setting('qa.friend_code'));
  exception when insufficient_privilege then failed:=true; end;
  assert failed, 'Banned user cannot resolve invites';
end $$;
reset role;
update private.social_invites set expires_at=now()-interval '1 second' where token=current_setting('qa.friend_code');
select set_config('request.jwt.claim.sub','a0ce0000-0000-4000-8000-000000000005',true);
set local role authenticated;
do $$ declare failed boolean:=false;
begin
  begin perform public.accept_social_invite(current_setting('qa.friend_code'));
  exception when invalid_parameter_value then failed:=true; end;
  assert failed, 'Expired invite cannot redeem';
  failed := false;
  begin perform public.resolve_social_invite('00000000000000000000000000000000');
  exception when invalid_parameter_value then failed:=true; end;
  assert failed, 'Unknown invite is unavailable';
end $$;
reset role;
select 'PASS: solo groups, share reuse, explicit join, recipient consent, request retries, public preview fields, private posts, blocks, bans, expiry, anonymous denial' as result;
rollback;
