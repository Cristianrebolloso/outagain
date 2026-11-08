-- Local sharing is opt-in. Existing posts keep their existing audience.
alter table public.posts add column if not exists is_shared_locally boolean not null default false;
alter table public.notification_preferences add column if not exists recaps_enabled boolean not null default true;
alter table public.notifications
  add column if not exists night_start timestamptz,
  add column if not exists night_end timestamptz,
  add column if not exists night_group_id uuid;

create schema if not exists private;
create table if not exists private.discovery_context (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  latitude double precision,
  longitude double precision,
  location_updated_at timestamptz,
  time_zone text not null default 'UTC',
  last_opened_at timestamptz not null default now(),
  recap_viewed_through timestamptz
);
alter table private.discovery_context enable row level security;
revoke all on private.discovery_context from public, anon, authenticated;

create table if not exists private.night_recap_deliveries (
  user_id uuid not null references public.profiles(id) on delete cascade,
  night_start timestamptz not null,
  notification_id uuid,
  primary key (user_id, night_start)
);
alter table private.night_recap_deliveries enable row level security;
revoke all on private.night_recap_deliveries from public, anon, authenticated;

create or replace function private.users_can_interact(first_id uuid, second_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select first_id is not null and second_id is not null
    and not public.is_profile_banned(first_id) and not public.is_profile_banned(second_id)
    and not exists (select 1 from public.friendships f where f.status = 'blocked'
      and ((f.user_id = first_id and f.friend_id = second_id)
        or (f.user_id = second_id and f.friend_id = first_id)));
$$;
revoke all on function private.users_can_interact(uuid,uuid) from public, anon, authenticated;

-- Restrictive parent checks prevent old friend/tag policies from bypassing a block.
create or replace function private.viewer_can_interact(other_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.users_can_interact(auth.uid(),other_id);
$$;
revoke all on function private.viewer_can_interact(uuid) from public,anon;
grant execute on function private.viewer_can_interact(uuid) to authenticated;
create policy "post audience excludes blocks and bans" on public.posts as restrictive for select to authenticated
using(private.viewer_can_interact(author_id));
create policy "comments require visible post" on public.comments as restrictive for insert to authenticated
with check(exists(select 1 from public.posts p where p.id=post_id));
create policy "reactions require visible post" on public.reactions as restrictive for insert to authenticated
with check(exists(select 1 from public.posts p where p.id=post_id));
create policy "comment likes require visible post" on public.comment_likes as restrictive for insert to authenticated
with check(exists(select 1 from public.comments c join public.posts p on p.id=c.post_id where c.id=comment_id));

create or replace function private.distance_meters(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable strict set search_path = '' as $$
  select 6371000.0 * 2 * asin(sqrt(least(1.0,
    power(sin(radians(lat2-lat1)/2),2)
    + cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2))));
$$;
revoke all on function private.distance_meters(double precision,double precision,double precision,double precision) from public, anon;
grant execute on function private.distance_meters(double precision,double precision,double precision,double precision) to authenticated;
grant usage on schema private to authenticated;

create or replace function private.update_discovery_context(viewer_time_zone text, viewer_latitude double precision, viewer_longitude double precision)
returns void language plpgsql security definer set search_path = '' as $$
declare viewer_id uuid := auth.uid();
begin
  if viewer_id is null or public.is_profile_banned(viewer_id) then raise exception 'Sign in to continue'; end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = viewer_time_zone) then
    raise exception 'Invalid time zone';
  end if;
  if (viewer_latitude is null) <> (viewer_longitude is null)
    or (viewer_latitude is not null and not (viewer_latitude between -90 and 90 and viewer_longitude between -180 and 180)) then
    raise exception 'Invalid location';
  end if;
  insert into private.discovery_context(user_id,time_zone,latitude,longitude,location_updated_at,last_opened_at)
  values(viewer_id,viewer_time_zone,viewer_latitude,viewer_longitude,
    case when viewer_latitude is not null then now() end,now())
  on conflict(user_id) do update set time_zone=excluded.time_zone,last_opened_at=excluded.last_opened_at,
    latitude=coalesce(excluded.latitude,discovery_context.latitude),
    longitude=coalesce(excluded.longitude,discovery_context.longitude),
    location_updated_at=coalesce(excluded.location_updated_at,discovery_context.location_updated_at);
end;
$$;
revoke all on function private.update_discovery_context(text,double precision,double precision) from public, anon;
grant execute on function private.update_discovery_context(text,double precision,double precision) to authenticated;
create or replace function public.update_discovery_context(viewer_time_zone text, viewer_latitude double precision default null, viewer_longitude double precision default null)
returns void language sql security invoker set search_path = '' as $$
  select private.update_discovery_context(viewer_time_zone,viewer_latitude,viewer_longitude);
$$;
revoke all on function public.update_discovery_context(text,double precision,double precision) from public, anon;
grant execute on function public.update_discovery_context(text,double precision,double precision) to authenticated;

create or replace function private.can_read_local_post(post_author_id uuid,post_latitude double precision,post_longitude double precision,posted_at timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.users_can_interact(auth.uid(),post_author_id)
    and posted_at >= now()-interval '48 hours'
    and exists(select 1 from private.discovery_context c where c.user_id=auth.uid()
      and c.location_updated_at >= now()-interval '24 hours'
      and private.distance_meters(c.latitude,c.longitude,post_latitude,post_longitude) <= 8046.72);
$$;
revoke all on function private.can_read_local_post(uuid,double precision,double precision,timestamptz) from public, anon;
grant execute on function private.can_read_local_post(uuid,double precision,double precision,timestamptz) to authenticated;

create or replace function private.prepare_local_post()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.is_shared_locally then
    if new.latitude is null or new.longitude is null
      or not (new.latitude between -90 and 90 and new.longitude between -180 and 180) then
      raise exception 'Location is required to share to Local';
    end if;
    -- The row itself contains only a coarse area when shared outside friends.
    new.latitude := round(new.latitude::numeric,2)::double precision;
    new.longitude := round(new.longitude::numeric,2)::double precision;
    new.horizontal_accuracy := greatest(coalesce(new.horizontal_accuracy,0),1100);
    new.venue_name := null;
    new.venue_neighborhood := null;
    new.venue_latitude := null;
    new.venue_longitude := null;
  end if;
  return new;
end;
$$;
revoke all on function private.prepare_local_post() from public, anon, authenticated;
create trigger posts_prepare_local before insert or update on public.posts
for each row execute function private.prepare_local_post();

create index if not exists posts_local_recent_idx on public.posts(created_at desc,id desc) where is_shared_locally;
create policy "opted in nearby posts readable" on public.posts for select to authenticated
using(is_shared_locally and private.can_read_local_post(author_id,latitude,longitude,created_at));

-- Child reads use the parent post's RLS, which includes its selected audience.
create policy "comments readable with locally visible parent" on public.comments for select to authenticated
using(exists(select 1 from public.posts p where p.id=post_id and p.is_shared_locally
  and private.can_read_local_post(p.author_id,p.latitude,p.longitude,p.created_at)));
create policy "reactions readable with locally visible parent" on public.reactions for select to authenticated
using(exists(select 1 from public.posts p where p.id=post_id and p.is_shared_locally
  and private.can_read_local_post(p.author_id,p.latitude,p.longitude,p.created_at)));
create policy "comment likes readable with visible parent" on public.comment_likes for select to authenticated
using(exists(select 1 from public.comments c join public.posts p on p.id=c.post_id where c.id=comment_id));
create policy "comment likes insert with visible parent" on public.comment_likes for insert to authenticated
with check(user_id=auth.uid() and exists(select 1 from public.comments c join public.posts p on p.id=c.post_id where c.id=comment_id));

create or replace function public.local_feed_posts(before_date timestamptz default null,before_id uuid default null,page_limit integer default 25)
returns setof public.posts language sql stable security invoker set search_path = '' as $$
  select p.* from public.posts p where p.is_shared_locally and p.created_at >= now()-interval '48 hours'
    and private.can_read_local_post(p.author_id,p.latitude,p.longitude,p.created_at)
    and (before_date is null or p.created_at < before_date
      or (p.created_at=before_date and before_id is not null and p.id<before_id))
  order by p.created_at desc,p.id desc limit greatest(1,least(page_limit,51));
$$;
revoke all on function public.local_feed_posts(timestamptz,uuid,integer) from public, anon;
grant execute on function public.local_feed_posts(timestamptz,uuid,integer) to authenticated;

create or replace function public.night_recap_posts(window_start timestamptz,window_end timestamptz,group_id uuid default null)
returns setof public.posts language sql stable security invoker set search_path = '' as $$
  select p.* from public.posts p
  where window_end>window_start and window_end-window_start<=interval '25 hours'
    and window_end<=now() and p.created_at>=window_start and p.created_at<window_end
    and (p.author_id=auth.uid() or public.is_friend(auth.uid(),p.author_id) or auth.uid()=any(p.tagged_user_ids))
    and (group_id is null or exists(select 1 from public.night_groups g where g.id=group_id
      and auth.uid()=any(g.member_ids) and p.author_id=any(g.member_ids)))
  order by p.created_at,p.id limit 500;
$$;
revoke all on function public.night_recap_posts(timestamptz,timestamptz,uuid) from public, anon;
grant execute on function public.night_recap_posts(timestamptz,timestamptz,uuid) to authenticated;

create or replace function private.mark_night_recap_seen(window_end timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in to continue'; end if;
  if window_end>now() then raise exception 'Invalid recap date'; end if;
  update private.discovery_context set recap_viewed_through=greatest(recap_viewed_through,window_end) where user_id=auth.uid();
end;
$$;
revoke all on function private.mark_night_recap_seen(timestamptz) from public,anon;
grant execute on function private.mark_night_recap_seen(timestamptz) to authenticated;
create or replace function public.mark_night_recap_seen(window_end timestamptz)
returns void language sql security invoker set search_path = '' as $$ select private.mark_night_recap_seen(window_end); $$;
revoke all on function public.mark_night_recap_seen(timestamptz) from public,anon;
grant execute on function public.mark_night_recap_seen(timestamptz) to authenticated;

create or replace function public.notify_on_tag()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor_name text;
begin
  select display_name into actor_name from public.profiles where id=new.author_id;
  insert into public.notifications(user_id,actor_id,post_id,kind,title,detail)
  select distinct tagged_id,new.author_id,new.id,'tagged',coalesce(actor_name,'Someone')||' tagged you in a photo','Tap to see the photo.'
  from unnest(new.tagged_user_ids) tagged_id
  where tagged_id<>new.author_id and private.users_can_interact(tagged_id,new.author_id);
  return new;
end;
$$;
revoke all on function public.notify_on_tag() from public,anon,authenticated;

create or replace function public.notify_on_post()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor_name text; cycle_start timestamptz; actor_zone text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.author_id::text,0));
  select coalesce((select time_zone from private.discovery_context where user_id=new.author_id),'America/Chicago') into actor_zone;
  cycle_start := (date_trunc('day',(new.created_at at time zone actor_zone)-interval '7 hours')+interval '7 hours') at time zone actor_zone;
  if exists(select 1 from public.posts p where p.author_id=new.author_id and p.id<>new.id and p.created_at>=cycle_start and p.created_at<=new.created_at) then return new; end if;
  select display_name into actor_name from public.profiles where id=new.author_id;
  insert into public.notifications(user_id,actor_id,post_id,kind,title,detail)
  select friend_id,new.author_id,new.id,'friendPost',coalesce(actor_name,'A friend')||' just posted','See their night on Out Again.'
  from (select f.friend_id from public.friendships f where f.user_id=new.author_id and f.status='accepted'
    union select f.user_id from public.friendships f where f.friend_id=new.author_id and f.status='accepted') friends
  where friend_id<>new.author_id and not(friend_id=any(new.tagged_user_ids))
    and private.users_can_interact(friend_id,new.author_id);
  return new;
end;
$$;
revoke all on function public.notify_on_post() from public,anon,authenticated;

-- One late-morning recap per account/night, including friends who did not post.
-- Only upgraded clients register a context, so older clients receive no new kind.
create or replace function private.enqueue_night_recaps(reference_time timestamptz default now())
returns integer language plpgsql security definer set search_path = '' as $$
declare c record; night_start_at timestamptz; night_end_at timestamptz; local_now timestamp;
  photo_count integer; tag_count integer; group_to_open uuid; notification_to_create uuid; claimed integer; sent integer:=0;
begin
  update private.discovery_context set latitude=null,longitude=null,location_updated_at=null
    where location_updated_at<reference_time-interval '24 hours';
  delete from private.discovery_context where last_opened_at<reference_time-interval '30 days';
  delete from private.night_recap_deliveries where night_start<reference_time-interval '35 days';
  for c in select dc.* from private.discovery_context dc left join public.notification_preferences np on np.user_id=dc.user_id
    where coalesce(np.recaps_enabled,true) and not public.is_profile_banned(dc.user_id)
      and dc.last_opened_at>reference_time-interval '30 days'
  loop
    local_now := reference_time at time zone c.time_zone;
    if extract(hour from local_now)<11 or extract(hour from local_now)>=13 then continue; end if;
    night_end_at := (date_trunc('day',local_now)+interval '7 hours') at time zone c.time_zone;
    night_start_at := (date_trunc('day',local_now)-interval '1 day'+interval '7 hours') at time zone c.time_zone;
    if c.last_opened_at>=night_end_at or c.recap_viewed_through>=night_end_at then continue; end if;
    select count(*),count(*) filter(where c.user_id=any(p.tagged_user_ids)) into photo_count,tag_count
    from public.posts p where p.created_at>=night_start_at and p.created_at<night_end_at and p.image_path is not null
      and private.users_can_interact(c.user_id,p.author_id)
      and (p.author_id=c.user_id or public.is_friend(c.user_id,p.author_id) or c.user_id=any(p.tagged_user_ids));
    if photo_count<3 and tag_count=0 then continue; end if;
    group_to_open := null;
    select g.id into group_to_open from public.night_groups g where c.user_id=any(g.member_ids)
      and g.created_at>=night_start_at and g.created_at<night_end_at
      and (select count(*) from public.posts p where p.author_id=any(g.member_ids)
        and p.created_at>=night_start_at and p.created_at<night_end_at and p.image_path is not null
        and private.users_can_interact(c.user_id,p.author_id)
        and (p.author_id=c.user_id or public.is_friend(c.user_id,p.author_id) or c.user_id=any(p.tagged_user_ids)))>=3
      order by g.created_at desc limit 1;
    if group_to_open is not null then
      select count(*) into photo_count from public.posts p join public.night_groups g on g.id=group_to_open
      where p.author_id=any(g.member_ids) and p.created_at>=night_start_at and p.created_at<night_end_at and p.image_path is not null
        and private.users_can_interact(c.user_id,p.author_id)
        and (p.author_id=c.user_id or public.is_friend(c.user_id,p.author_id) or c.user_id=any(p.tagged_user_ids));
    end if;
    notification_to_create:=gen_random_uuid();
    insert into private.night_recap_deliveries(user_id,night_start,notification_id)
    values(c.user_id,night_start_at,notification_to_create) on conflict do nothing;
    get diagnostics claimed=row_count;
    if claimed=0 then continue; end if;
    insert into public.notifications(id,user_id,kind,title,detail,night_start,night_end,night_group_id)
    values(notification_to_create,c.user_id,'nightRecap',
      case when group_to_open is not null then 'Your group''s photos from last night' else 'Last night''s photos are ready' end,
      photo_count||case when photo_count=1 then ' photo to look back on.' else ' photos to look back on.' end,
      night_start_at,night_end_at,group_to_open);
    sent:=sent+1;
  end loop;
  return sent;
end;
$$;
revoke all on function private.enqueue_night_recaps(timestamptz) from public,anon,authenticated;

create extension if not exists pg_cron;
select cron.schedule('outagain-night-recaps','*/15 * * * *','select private.enqueue_night_recaps();');

CREATE OR REPLACE FUNCTION public.dispatch_notification_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  target_supabase_url text := 'https://xissvzlusznqpxvwnwpu.supabase.co';
  service_role_key text;
  net_request_id bigint;
  attempt_id uuid;
  now_utc timestamptz := timezone('utc', now());
  v_dedupe_key text;
  should_dispatch boolean := true;
begin
  insert into public.push_attempts (
    notification_id, recipient_user_id, kind, status, announcement_id
  ) values (
    new.id, new.user_id, new.kind, 'pending', new.announcement_id
  )
  returning id into attempt_id;

  v_dedupe_key := md5(concat_ws(
    '|',
    new.user_id::text,
    coalesce(new.actor_id::text, ''),
    coalesce(new.kind, ''),
    coalesce(new.post_id::text, ''),
    coalesce(new.comment_id::text, ''),
    coalesce(new.title, ''),
    coalesce(new.detail, '')
  ));

  if random() < 0.02 then
    delete from public.notification_push_dedupe
    where last_dispatched_at < now_utc - interval '1 day';
  end if;

  with upserted as (
    insert into public.notification_push_dedupe (
      dedupe_key,
      notification_id,
      last_dispatched_at
    ) values (
      v_dedupe_key,
      new.id,
      now_utc
    )
    on conflict (dedupe_key) do update
      set last_dispatched_at = case
            when public.notification_push_dedupe.last_dispatched_at
                   < excluded.last_dispatched_at - interval '2 minutes'
            then excluded.last_dispatched_at
            else public.notification_push_dedupe.last_dispatched_at
          end,
          notification_id = case
            when public.notification_push_dedupe.last_dispatched_at
                   < excluded.last_dispatched_at - interval '2 minutes'
            then excluded.notification_id
            else public.notification_push_dedupe.notification_id
          end
    returning notification_id = new.id as can_dispatch
  )
  select can_dispatch into should_dispatch
  from upserted;

  if should_dispatch is distinct from true then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'duplicate push notification within 2 minutes',
           completed_at = now_utc
     where id = attempt_id;
    return new;
  end if;

  begin
    select decrypted_secret into service_role_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;
  exception when others then
    service_role_key := null;
  end;

  if service_role_key is null or service_role_key = '' then
    update public.push_attempts
       set status = 'skipped',
           skip_reason = 'missing vault secret supabase_service_role_key',
           completed_at = now_utc
     where id = attempt_id;
    return new;
  end if;

  begin
    select net.http_post(
      url := target_supabase_url || '/functions/v1/notify-activity',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || service_role_key
      ),
      body := jsonb_build_object(
        'notificationId', new.id,
        'recipientUserId', new.user_id,
        'actorUserId', new.actor_id,
        'kind', new.kind,
        'title', new.title,
        'body', new.detail,
        'postId', new.post_id,
        'commentId', new.comment_id,
        'nightStart', new.night_start,
        'nightEnd', new.night_end,
        'nightGroupId', new.night_group_id
      )
    ) into net_request_id;

    update public.push_attempts
       set status = 'dispatched',
           request_id = net_request_id
     where id = attempt_id;
  exception when others then
    update public.push_attempts
       set status = 'errored',
           error_message = left(sqlerrm, 500),
           completed_at = now_utc
     where id = attempt_id;
  end;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.submit_content_report(target_type text, target_post_id uuid DEFAULT NULL::uuid, target_comment_id uuid DEFAULT NULL::uuid, target_user_id uuid DEFAULT NULL::uuid, detail text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  current_user_id uuid := auth.uid();
  requested_target_type text := lower(btrim(coalesce(submit_content_report.target_type, '')));
  sanitized_detail text := left(
    regexp_replace(btrim(coalesce(submit_content_report.detail, '')), '[[:space:]]+', ' ', 'g'),
    500
  );
  reporter_username text;
  resolved_post_id uuid;
  resolved_comment_id uuid;
  resolved_author_id uuid;
  resolved_author_username text;
  resolved_excerpt text;
  inserted_report_id uuid;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to submit a report.' using errcode = '42501';
  end if;

  select left(
    coalesce(nullif(btrim(p.username), ''), nullif(btrim(p.display_name), ''), 'unknown'),
    64
  )
  into reporter_username
  from public.profiles p
  where p.id = current_user_id;

  if reporter_username is null then
    raise exception 'You must finish your profile before submitting a report.' using errcode = '42501';
  end if;

  if requested_target_type = 'post' then
    if submit_content_report.target_post_id is null
       or submit_content_report.target_comment_id is not null
       or submit_content_report.target_user_id is not null then
      raise exception 'Invalid post report target.' using errcode = '22023';
    end if;

    select
      p.id,
      p.author_id,
      left(coalesce(nullif(btrim(author.username), ''), nullif(btrim(author.display_name), ''), 'unknown'), 64),
      left(
        coalesce(
          nullif(btrim(p.caption), ''),
          case
            when nullif(btrim(coalesce(p.venue_name, '')), '') is not null then
              concat(coalesce(nullif(btrim(p.drink_name), ''), 'Moment'), ' at ', btrim(p.venue_name))
            else coalesce(nullif(btrim(p.drink_name), ''), 'Moment')
          end
        ),
        240
      )
    into resolved_post_id, resolved_author_id, resolved_author_username, resolved_excerpt
    from public.posts p
    join public.profiles author on author.id = p.author_id
    where p.id = submit_content_report.target_post_id
      and private.users_can_interact(auth.uid(),p.author_id)
      and (public.can_read_post(p.author_id, p.tagged_user_ids)
        or (p.is_shared_locally and private.can_read_local_post(p.author_id,p.latitude,p.longitude,p.created_at)));

    if not found then
      raise exception 'Reported post was not found or is not visible.' using errcode = '42501';
    end if;
  elsif requested_target_type = 'comment' then
    if submit_content_report.target_post_id is null
       or submit_content_report.target_comment_id is null
       or submit_content_report.target_user_id is not null then
      raise exception 'Invalid comment report target.' using errcode = '22023';
    end if;

    select
      c.post_id,
      c.id,
      c.author_id,
      left(coalesce(nullif(btrim(author.username), ''), nullif(btrim(author.display_name), ''), 'unknown'), 64),
      left(
        coalesce(
          nullif(btrim(c.body), ''),
          case c.kind
            when 'photo' then '[Photo comment]'
            when 'gif' then '[GIF comment]'
            else '(empty comment)'
          end
        ),
        240
      )
    into resolved_post_id, resolved_comment_id, resolved_author_id, resolved_author_username, resolved_excerpt
    from public.comments c
    join public.posts p on p.id = c.post_id
    join public.profiles author on author.id = c.author_id
    where c.id = submit_content_report.target_comment_id
      and c.post_id = submit_content_report.target_post_id
      and private.users_can_interact(auth.uid(),p.author_id)
      and (public.can_read_post(p.author_id, p.tagged_user_ids)
        or (p.is_shared_locally and private.can_read_local_post(p.author_id,p.latitude,p.longitude,p.created_at)));

    if not found then
      raise exception 'Reported comment was not found or is not visible.' using errcode = '42501';
    end if;
  elsif requested_target_type = 'user' then
    if submit_content_report.target_user_id is null
       or submit_content_report.target_post_id is not null
       or submit_content_report.target_comment_id is not null then
      raise exception 'Invalid user report target.' using errcode = '22023';
    end if;

    select
      p.id,
      left(coalesce(nullif(btrim(p.username), ''), nullif(btrim(p.display_name), ''), 'unknown'), 64),
      left(
        concat(
          'User profile: @',
          coalesce(nullif(btrim(p.username), ''), nullif(btrim(p.display_name), ''), 'unknown')
        ),
        240
      )
    into resolved_author_id, resolved_author_username, resolved_excerpt
    from public.profiles p
    where p.id = submit_content_report.target_user_id;

    if not found then
      raise exception 'Reported user was not found.' using errcode = '42501';
    end if;
  else
    raise exception 'Invalid report target type.' using errcode = '22023';
  end if;

  insert into public.content_reports (
    reporter_id,
    reporter_username,
    target_type,
    target_post_id,
    target_comment_id,
    target_author_id,
    target_author_username,
    target_excerpt,
    reason,
    detail
  )
  values (
    current_user_id,
    reporter_username,
    requested_target_type,
    resolved_post_id,
    resolved_comment_id,
    resolved_author_id,
    resolved_author_username,
    resolved_excerpt,
    'community_report',
    sanitized_detail
  )
  returning id into inserted_report_id;

  return inserted_report_id;
end;
$function$;
