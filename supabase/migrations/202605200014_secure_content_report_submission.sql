-- Route community reports through a server-side RPC so moderation metadata
-- cannot be forged by a client insert.

revoke insert on table public.content_reports from anon, authenticated;

drop policy if exists "users can submit content reports" on public.content_reports;
drop policy if exists "content reports cannot be inserted directly" on public.content_reports;
create policy "content reports cannot be inserted directly"
on public.content_reports
for insert
to authenticated
with check (false);

create or replace function public.submit_content_report(
  target_type text,
  target_post_id uuid default null,
  target_comment_id uuid default null,
  target_user_id uuid default null,
  detail text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
      and public.can_read_post(p.author_id, p.tagged_user_ids);

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
      and public.can_read_post(p.author_id, p.tagged_user_ids);

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
$$;

revoke all on function public.submit_content_report(text, uuid, uuid, uuid, text) from public;
revoke all on function public.submit_content_report(text, uuid, uuid, uuid, text) from anon;
grant execute on function public.submit_content_report(text, uuid, uuid, uuid, text) to authenticated;
