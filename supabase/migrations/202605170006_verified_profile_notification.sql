-- Notify a user only when their profile first flips into the verified state.

create or replace function public.notify_profile_verified()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (user_id, actor_id, kind, title, detail)
  values (
    new.id,
    null,
    'profileVerified',
    'You''re verified on Out Again',
    'Your profile now has the verified badge.'
  );

  return new;
end;
$$;

drop trigger if exists profiles_notify_verified on public.profiles;

create trigger profiles_notify_verified
after update of is_verified on public.profiles
for each row
when (new.is_verified = true and old.is_verified is distinct from true)
execute procedure public.notify_profile_verified();
