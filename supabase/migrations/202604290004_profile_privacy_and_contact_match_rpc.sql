-- Lock down private profile columns so normal client reads can't harvest
-- Apple identifiers or contact-match hashes. Contact discovery keeps working
-- through a narrow RPC that returns only the public profile fields.

create or replace function public.match_profiles_by_email_hashes(email_hashes text[])
returns table (
  id uuid,
  username text,
  display_name text,
  avatar_path text,
  avatar_version integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.avatar_version
  from public.profiles p
  where p.normalized_email_hash = any(coalesce(email_hashes, '{}'::text[]))
    and p.username is not null
  order by p.created_at desc
  limit 24;
$$;

grant execute on function public.match_profiles_by_email_hashes(text[]) to authenticated;

revoke select (apple_user_identifier, normalized_email_hash)
on table public.profiles
from authenticated, anon;
