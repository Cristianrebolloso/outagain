-- Qualify the argument positionally: banned_users.user_id previously shadowed
-- the function argument, making any row in banned_users match every account.
create or replace function public.is_profile_banned(user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select p.is_banned from public.profiles p where p.id=$1),false)
    or exists (select 1 from public.banned_users b where b.user_id=$1)
    or exists (
      select 1 from auth.users u
      join public.banned_users b on b.email_hash=public.normalized_email_sha256(u.email)
      where u.id=$1 and b.email_hash is not null
    );
$$;
