create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null,
  reporter_username text not null,
  target_type text not null check (target_type in ('post', 'comment')),
  target_post_id uuid,
  target_comment_id uuid,
  target_author_id uuid not null,
  target_author_username text not null,
  target_excerpt text not null default '',
  reason text not null default 'community_report',
  detail text not null default '',
  status text not null default 'open' check (status in ('open', 'reviewed', 'dismissed', 'actioned')),
  reviewed_at timestamptz,
  moderator_note text,
  created_at timestamptz not null default timezone('utc', now()),
  constraint content_reports_target_shape check (
    (target_type = 'post' and target_post_id is not null and target_comment_id is null)
    or
    (target_type = 'comment' and target_post_id is not null and target_comment_id is not null)
  )
);

create index if not exists content_reports_created_at_idx
  on public.content_reports (created_at desc);

create index if not exists content_reports_status_created_at_idx
  on public.content_reports (status, created_at desc);

create unique index if not exists content_reports_reporter_post_unique_idx
  on public.content_reports (reporter_id, target_post_id)
  where target_type = 'post';

create unique index if not exists content_reports_reporter_comment_unique_idx
  on public.content_reports (reporter_id, target_comment_id)
  where target_type = 'comment';

alter table public.content_reports enable row level security;

drop policy if exists "users can submit content reports" on public.content_reports;
create policy "users can submit content reports"
on public.content_reports
for insert
to authenticated
with check (auth.uid() = reporter_id);

update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/heic', 'image/gif']
where id = 'moments';
