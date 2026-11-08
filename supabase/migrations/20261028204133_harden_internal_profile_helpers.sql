-- Profile triggers use qualified relations/auth helpers and built-in functions.
-- Pin resolution so a caller cannot change which function an internal call uses.
alter function public.bump_avatar_version() set search_path = '';
alter function public.touch_updated_at() set search_path = '';
alter function public.protect_profile_verification() set search_path = '';
alter function public.protect_profile_moderation_fields() set search_path = '';

-- Only server-owned moderation/signup functions need an account's email hash.
-- This is not a client RPC; keep it unavailable to anonymous or signed-in users.
alter function public.auth_user_email_hash(uuid) set search_path = '';
revoke all on function public.auth_user_email_hash(uuid) from public, anon, authenticated;
grant execute on function public.auth_user_email_hash(uuid) to service_role;
