-- Fix admin trigger permissions.
--
-- The protect_profile_verification and protect_profile_moderation_fields
-- triggers both check coalesce(auth.role(), current_user) to allow service_role
-- / postgres / supabase_admin through. However, even inside a SECURITY DEFINER
-- function, auth.role() returns 'authenticated' (it reads from the JWT claim,
-- not the PostgreSQL execution role), so coalesce always picks 'authenticated'
-- and the triggers block the update with an exception.
--
-- Fix: add an is_app_admin(auth.uid()) early-return in both trigger functions so
-- the @admin account can actually call admin_set_profile_verified and
-- admin_set_user_banned through the PostgREST API.

create or replace function public.protect_profile_verification()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), current_user) in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  -- Allow the @admin account to change verification status via the
  -- admin_set_profile_verified RPC. auth.role() stays 'authenticated'
  -- even inside security definer functions, so the role check above
  -- never passes for PostgREST API calls.
  if public.is_app_admin(auth.uid()) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.is_verified = false;
    return new;
  end if;

  if new.is_verified is distinct from old.is_verified then
    raise exception 'Only app admins can change profile verification.';
  end if;

  return new;
end;
$$;

create or replace function public.protect_profile_moderation_fields()
returns trigger
language plpgsql
as $$
begin
  if coalesce(auth.role(), current_user) in ('service_role', 'postgres', 'supabase_admin') then
    return new;
  end if;

  -- Allow the @admin account to change ban fields via admin_set_user_banned.
  -- Same auth.role() / JWT issue as protect_profile_verification above.
  if public.is_app_admin(auth.uid()) then
    -- The @admin account cannot ban itself (enforced in the RPC layer, but
    -- guard here too so the trigger is self-contained).
    if public.is_app_admin(new.id) then
      raise exception 'The @admin account cannot be banned.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.is_banned = false;
    new.banned_at = null;
    new.banned_by = null;
    new.ban_reason = null;
    return new;
  end if;

  if new.is_banned is distinct from old.is_banned
     or new.banned_at is distinct from old.banned_at
     or new.banned_by is distinct from old.banned_by
     or new.ban_reason is distinct from old.ban_reason
  then
    raise exception 'Only @admin can change moderation status.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;
