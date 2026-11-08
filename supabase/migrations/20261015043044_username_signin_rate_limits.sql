-- Only the sign-in Edge Function can use these counters. No account data is
-- returned, and callers cannot resolve usernames to private email addresses.
create table public.username_signin_rate_limits (
  key_hash text primary key,
  window_started_at timestamptz not null,
  attempts integer not null check (attempts > 0)
);
alter table public.username_signin_rate_limits enable row level security;
revoke all on public.username_signin_rate_limits from public, anon, authenticated;
grant select, insert, update, delete on public.username_signin_rate_limits to service_role;

create function public.consume_username_signin_attempt(key_hash text, attempt_limit integer)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  current_attempts integer;
begin
  if key_hash is null or length(key_hash) <> 64 or attempt_limit not between 1 and 100 then
    return false;
  end if;

  insert into public.username_signin_rate_limits as limits (key_hash, window_started_at, attempts)
  values (consume_username_signin_attempt.key_hash, now(), 1)
  on conflict on constraint username_signin_rate_limits_pkey do update
    set window_started_at = case when limits.window_started_at <= now() - interval '5 minutes'
                                  then now() else limits.window_started_at end,
        attempts = case when limits.window_started_at <= now() - interval '5 minutes'
                        then 1 else least(limits.attempts + 1, 101) end
  returning attempts into current_attempts;

  if random() < 0.02 then
    delete from public.username_signin_rate_limits where window_started_at < now() - interval '1 day';
  end if;
  return current_attempts <= attempt_limit;
end;
$$;
revoke all on function public.consume_username_signin_attempt(text, integer) from public, anon, authenticated;
grant execute on function public.consume_username_signin_attempt(text, integer) to service_role;
