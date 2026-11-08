-- Missing preferences mean enabled. Additive defaults preserve existing
-- Announcements opt-outs, and older clients can still write that column alone.
alter table public.notification_preferences
  add column if not exists friend_requests_enabled boolean not null default true,
  add column if not exists reactions_enabled boolean not null default true,
  add column if not exists comments_enabled boolean not null default true,
  add column if not exists activity_enabled boolean not null default true;

comment on table public.notification_preferences is
  'Account-wide push opt-outs. All categories default to true; an absent row is enabled. Live Activities remain a device preference.';
