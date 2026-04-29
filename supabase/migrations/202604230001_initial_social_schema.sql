create extension if not exists pgcrypto;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null,
  avatar_path text,
  apple_user_identifier text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
before update on public.profiles
for each row
execute procedure public.touch_updated_at();

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  friend_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'accepted' check (status in ('pending', 'accepted', 'blocked')),
  created_at timestamptz not null default timezone('utc', now()),
  unique (user_id, friend_id),
  check (user_id <> friend_id)
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles (id) on delete cascade,
  drink_name text not null,
  drink_subtitle text not null default '',
  drink_symbol text not null default 'wineglass',
  drink_primary_hex text not null default '#D98B3D',
  drink_secondary_hex text not null default '#281916',
  venue_name text,
  venue_neighborhood text,
  venue_city text,
  venue_latitude double precision,
  venue_longitude double precision,
  latitude double precision,
  longitude double precision,
  horizontal_accuracy double precision,
  caption text not null,
  image_path text,
  tagged_user_ids uuid[] not null default '{}',
  is_shared_moment boolean not null default false,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists posts_author_created_at_idx on public.posts (author_id, created_at desc);
create index if not exists posts_created_at_idx on public.posts (created_at desc);

create table if not exists public.comments (
  id uuid primary key,
  post_id uuid not null references public.posts (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null,
  kind text not null default 'text' check (kind in ('text', 'photo', 'gif')),
  reply_to_comment_id uuid references public.comments (id) on delete set null,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists comments_post_created_at_idx on public.comments (post_id, created_at desc);

create table if not exists public.reactions (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('cheers', 'spark', 'fire')),
  created_at timestamptz not null default timezone('utc', now()),
  unique (post_id, user_id, kind)
);

create index if not exists reactions_post_created_at_idx on public.reactions (post_id, created_at desc);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete set null,
  post_id uuid references public.posts (id) on delete cascade,
  comment_id uuid references public.comments (id) on delete cascade,
  kind text not null,
  title text not null,
  detail text not null,
  read_at timestamptz,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists notifications_user_created_at_idx on public.notifications (user_id, created_at desc);

create table if not exists public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  apns_token text not null,
  environment text not null check (environment in ('development', 'production')),
  last_seen_at timestamptz not null default timezone('utc', now()),
  unique (user_id, apns_token)
);

create or replace function public.notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  drink_name text;
  recipient_id uuid;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.user_id;

  select posts.author_id, posts.drink_name
    into recipient_id, drink_name
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is not null and recipient_id <> new.user_id then
    insert into public.notifications (user_id, actor_id, post_id, kind, title, detail)
    values (
      recipient_id,
      new.user_id,
      new.post_id,
      'reaction',
      coalesce(actor_name, 'Someone') || ' liked your post',
      initcap(new.kind) || ' on your ' || coalesce(drink_name, 'post') || '.'
    );
  end if;

  return new;
end;
$$;

drop trigger if exists reactions_notify_insert on public.reactions;
create trigger reactions_notify_insert
after insert on public.reactions
for each row
execute procedure public.notify_on_reaction();

create or replace function public.notify_on_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_name text;
  recipient_id uuid;
begin
  select profiles.display_name into actor_name
  from public.profiles
  where profiles.id = new.author_id;

  select posts.author_id
    into recipient_id
  from public.posts
  where posts.id = new.post_id;

  if recipient_id is not null and recipient_id <> new.author_id then
    insert into public.notifications (user_id, actor_id, post_id, comment_id, kind, title, detail)
    values (
      recipient_id,
      new.author_id,
      new.post_id,
      new.id,
      case when new.kind = 'photo' then 'photoReply' else 'comment' end,
      coalesce(actor_name, 'Someone') || ' commented on your post',
      left(new.body, 160)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists comments_notify_insert on public.comments;
create trigger comments_notify_insert
after insert on public.comments
for each row
execute procedure public.notify_on_comment();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 6291456, array['image/jpeg', 'image/png', 'image/heic']),
  ('moments', 'moments', true, 6291456, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.reactions enable row level security;
alter table public.notifications enable row level security;
alter table public.devices enable row level security;

drop policy if exists "profiles are readable by signed-in users" on public.profiles;
create policy "profiles are readable by signed-in users"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists "users can insert own profile" on public.profiles;
create policy "users can insert own profile"
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile"
on public.profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "friendships are readable by participants" on public.friendships;
create policy "friendships are readable by participants"
on public.friendships
for select
to authenticated
using (auth.uid() = user_id or auth.uid() = friend_id);

drop policy if exists "users can create own friendships" on public.friendships;
create policy "users can create own friendships"
on public.friendships
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "users can update own friendships" on public.friendships;
create policy "users can update own friendships"
on public.friendships
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "posts are readable by signed-in users" on public.posts;
create policy "posts are readable by signed-in users"
on public.posts
for select
to authenticated
using (true);

drop policy if exists "users can create own posts" on public.posts;
create policy "users can create own posts"
on public.posts
for insert
to authenticated
with check (auth.uid() = author_id);

drop policy if exists "users can update own posts" on public.posts;
create policy "users can update own posts"
on public.posts
for update
to authenticated
using (auth.uid() = author_id)
with check (auth.uid() = author_id);

drop policy if exists "comments are readable by signed-in users" on public.comments;
create policy "comments are readable by signed-in users"
on public.comments
for select
to authenticated
using (true);

drop policy if exists "users can create own comments" on public.comments;
create policy "users can create own comments"
on public.comments
for insert
to authenticated
with check (auth.uid() = author_id);

drop policy if exists "users can manage own comments" on public.comments;
create policy "users can manage own comments"
on public.comments
for update
to authenticated
using (auth.uid() = author_id)
with check (auth.uid() = author_id);

drop policy if exists "reactions are readable by signed-in users" on public.reactions;
create policy "reactions are readable by signed-in users"
on public.reactions
for select
to authenticated
using (true);

drop policy if exists "users can create own reactions" on public.reactions;
create policy "users can create own reactions"
on public.reactions
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "users can delete own reactions" on public.reactions;
create policy "users can delete own reactions"
on public.reactions
for delete
to authenticated
using (auth.uid() = user_id);

drop policy if exists "users can read own notifications" on public.notifications;
create policy "users can read own notifications"
on public.notifications
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "users can update own notifications" on public.notifications;
create policy "users can update own notifications"
on public.notifications
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "users can manage own devices" on public.devices;
create policy "users can manage own devices"
on public.devices
for all
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "users can upload own avatars" on storage.objects;
create policy "users can upload own avatars"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = 'users'
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists "users can upload own moments" on storage.objects;
create policy "users can upload own moments"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'posts'
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists "public avatars are readable" on storage.objects;
create policy "public avatars are readable"
on storage.objects
for select
to authenticated, anon
using (bucket_id = 'avatars');

drop policy if exists "public moments are readable" on storage.objects;
create policy "public moments are readable"
on storage.objects
for select
to authenticated, anon
using (bucket_id = 'moments');
