-- Verified-only "did not fw" post reactions.
--
-- Dislikes are intentionally not a normal engagement affordance: only verified
-- users may create them, and the app only exposes the action to everyone once
-- at least one verified dislike exists on a post.

do $$
declare
  reaction_kind_constraint text;
begin
  select conname
    into reaction_kind_constraint
  from pg_constraint
  where conrelid = 'public.reactions'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%kind%'
  limit 1;

  if reaction_kind_constraint is not null then
    execute format(
      'alter table public.reactions drop constraint %I',
      reaction_kind_constraint
    );
  end if;
end;
$$;

alter table public.reactions
  add constraint reactions_kind_check
  check (kind in ('cheers', 'spark', 'fire', 'dislike'));

create or replace function public.enforce_verified_dislike_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_verified boolean;
begin
  if new.kind <> 'dislike' then
    return new;
  end if;

  select coalesce(p.is_verified, false)
    into actor_verified
  from public.profiles p
  where p.id = new.user_id;

  if actor_verified is distinct from true then
    raise exception 'Only verified users can dislike posts.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists reactions_enforce_verified_dislike on public.reactions;
create trigger reactions_enforce_verified_dislike
before insert or update of kind, user_id
on public.reactions
for each row
execute procedure public.enforce_verified_dislike_reaction();

drop policy if exists "users can create own reactions" on public.reactions;
create policy "users can create own reactions"
on public.reactions
for insert
to authenticated
with check (
  auth.uid() = user_id
  and (
    kind <> 'dislike'
    or exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.is_verified = true
    )
  )
);

drop function if exists public.post_engagement_counts(uuid[]);
create function public.post_engagement_counts(post_ids uuid[])
returns table (
  post_id uuid,
  comment_count integer,
  cheers_count integer,
  spark_count integer,
  fire_count integer,
  dislike_count integer,
  viewer_reaction_kinds text[]
)
language sql
stable
set search_path = public
as $$
  with target_posts as (
    select distinct unnest(coalesce(post_ids, '{}'::uuid[])) as post_id
  ),
  visible_posts as (
    select p.id as post_id
    from public.posts p
    join target_posts t on t.post_id = p.id
  ),
  comment_counts as (
    select c.post_id, count(*)::integer as comment_count
    from public.comments c
    join visible_posts vp on vp.post_id = c.post_id
    group by c.post_id
  ),
  reaction_counts as (
    select
      r.post_id,
      count(*) filter (where r.kind = 'cheers')::integer as cheers_count,
      count(*) filter (where r.kind = 'spark')::integer as spark_count,
      count(*) filter (where r.kind = 'fire')::integer as fire_count,
      count(*) filter (where r.kind = 'dislike')::integer as dislike_count,
      coalesce(
        array_agg(distinct r.kind) filter (where r.user_id = auth.uid()),
        '{}'::text[]
      ) as viewer_reaction_kinds
    from public.reactions r
    join visible_posts vp on vp.post_id = r.post_id
    group by r.post_id
  )
  select
    vp.post_id,
    coalesce(cc.comment_count, 0) as comment_count,
    coalesce(rc.cheers_count, 0) as cheers_count,
    coalesce(rc.spark_count, 0) as spark_count,
    coalesce(rc.fire_count, 0) as fire_count,
    coalesce(rc.dislike_count, 0) as dislike_count,
    coalesce(rc.viewer_reaction_kinds, '{}'::text[]) as viewer_reaction_kinds
  from visible_posts vp
  left join comment_counts cc on cc.post_id = vp.post_id
  left join reaction_counts rc on rc.post_id = vp.post_id;
$$;

grant execute on function public.post_engagement_counts(uuid[]) to authenticated;

create or replace function public.notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  recipient_id uuid;
  notification_title text;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  select posts.author_id
    into recipient_id
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is null or recipient_id = new.user_id then
    return new;
  end if;

  if new.kind = 'dislike' then
    notification_title := coalesce(actor_name, 'Someone') || ' did not fw your post';
  else
    notification_title := coalesce(actor_name, 'Someone') || ' liked your post';
  end if;

  -- Keep one reaction notification per actor+post; changing reaction type
  -- replaces the prior copy instead of stacking another notification.
  delete from public.notifications
  where user_id   = recipient_id
    and actor_id  = new.user_id
    and post_id   = new.post_id
    and kind      = 'reaction';

  insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
  values (
    recipient_id,
    new.user_id,
    new.post_id,
    'reaction',
    notification_title,
    notification_title
  );

  return new;
end;
$$;
