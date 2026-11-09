-- Apple-signed purchases only. No client role can grant an entitlement.
create table public.store_entitlements (
  original_transaction_id text not null,
  environment text not null check (environment in ('Production', 'Sandbox')),
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id text not null check (product_id in (
    'com.cristian.OutAgain.plus.monthly', 'com.cristian.OutAgain.plus.yearly',
    'com.cristian.OutAgain.background.night', 'com.cristian.OutAgain.background.orange',
    'com.cristian.OutAgain.background.green', 'com.cristian.OutAgain.background.pink',
    'com.cristian.OutAgain.background.blue'
  )),
  expires_at timestamptz,
  revoked_at timestamptz,
  signed_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (original_transaction_id, environment),
  check (product_id not like 'com.cristian.OutAgain.plus.%' or expires_at is not null)
);
create index store_entitlements_owner_idx on public.store_entitlements(user_id);
alter table public.store_entitlements enable row level security;
revoke all on public.store_entitlements from public, anon, authenticated;
grant select on public.store_entitlements to authenticated;
grant select, insert, update, delete on public.store_entitlements to service_role;
create policy "Owners read their purchases" on public.store_entitlements
  for select to authenticated using ((select auth.uid()) = user_id);

-- Only public membership status is shared, never transaction IDs or receipts.
create table public.plus_members (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  expires_at timestamptz not null
);
alter table public.plus_members enable row level security;
revoke all on public.plus_members from public, anon, authenticated;
grant select on public.plus_members to authenticated;
grant select, insert, update, delete on public.plus_members to service_role;
create policy "Signed in users see active Plus badges" on public.plus_members
  for select to authenticated using (expires_at > now());

-- SECURITY INVOKER: this RPC is executable only by the verified-receipt server.
create function public.record_verified_store_purchase(
  p_user_id uuid, p_original_transaction_id text, p_environment text,
  p_product_id text, p_expires_at timestamptz, p_revoked_at timestamptz,
  p_signed_at timestamptz
) returns void language plpgsql security invoker set search_path = '' as $$
declare owner_id uuid; plus_expiry timestamptz;
begin
  -- Serialize purchase delivery and Apple notifications for the same account.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  select user_id into owner_id from public.store_entitlements
    where original_transaction_id = p_original_transaction_id and environment = p_environment;
  if owner_id is not null and owner_id <> p_user_id then
    raise exception 'Purchase belongs to another account' using errcode = '42501';
  end if;
  insert into public.store_entitlements as existing
    (user_id, original_transaction_id, environment, product_id, expires_at, revoked_at, signed_at)
  values (p_user_id, p_original_transaction_id, p_environment, p_product_id, p_expires_at, p_revoked_at, p_signed_at)
  on conflict (original_transaction_id, environment) do update set
    product_id = excluded.product_id, expires_at = excluded.expires_at,
    revoked_at = excluded.revoked_at, signed_at = excluded.signed_at, updated_at = now()
  where existing.user_id = excluded.user_id and existing.signed_at < excluded.signed_at;
  if not exists (select 1 from public.store_entitlements where original_transaction_id = p_original_transaction_id
    and environment = p_environment and user_id = p_user_id) then
    raise exception 'Purchase belongs to another account' using errcode = '42501';
  end if;

  select max(expires_at) into plus_expiry from public.store_entitlements
    where user_id = p_user_id and environment = 'Production'
      and product_id in ('com.cristian.OutAgain.plus.monthly', 'com.cristian.OutAgain.plus.yearly')
      and revoked_at is null and expires_at > now();
  if plus_expiry is null then
    delete from public.plus_members where user_id = p_user_id;
  else
    insert into public.plus_members (user_id, expires_at) values (p_user_id, plus_expiry)
      on conflict (user_id) do update set expires_at = excluded.expires_at;
  end if;

  -- A refunded background or expired subscription falls back to the free theme.
  -- A separately bought background survives cancellation of Plus.
  update public.profiles p set background_theme = 'standard'
  where p.id = p_user_id and p.background_theme <> 'standard' and plus_expiry is null
    and not exists (select 1 from public.store_entitlements e where e.user_id = p.id
      and e.environment = 'Production' and e.revoked_at is null
      and e.product_id = 'com.cristian.OutAgain.background.' || p.background_theme);
end;
$$;
revoke all on function public.record_verified_store_purchase(uuid,text,text,text,timestamptz,timestamptz,timestamptz) from public, anon, authenticated;
grant execute on function public.record_verified_store_purchase(uuid,text,text,text,timestamptz,timestamptz,timestamptz) to service_role;

-- Retain the old choices privately so the one-time reset is recoverable.
create table private.background_reset_20261108 (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  previous_background text,
  reset_at timestamptz not null default now()
);
alter table private.background_reset_20261108 enable row level security;
revoke all on private.background_reset_20261108 from public, anon, authenticated;
insert into private.background_reset_20261108(user_id, previous_background)
  select id, background_theme from public.profiles;
update public.profiles set background_theme = 'standard'
  where background_theme is distinct from 'standard';

-- The function executes with the caller's RLS permissions: a client can see
-- only its own receipts, while the delivery service can maintain any account.
create function private.enforce_owned_background() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if new.background_theme is null or new.background_theme = 'standard' then return new; end if;
  if tg_op = 'UPDATE' and new.background_theme is not distinct from old.background_theme then return new; end if;
  if not exists (select 1 from public.store_entitlements e
    where e.user_id = new.id and e.environment = 'Production' and e.revoked_at is null
      and (e.product_id = 'com.cristian.OutAgain.background.' || new.background_theme
        or (e.product_id in ('com.cristian.OutAgain.plus.monthly', 'com.cristian.OutAgain.plus.yearly') and e.expires_at > now()))) then
    raise exception 'This background requires a purchase or active Out Again+ membership' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.enforce_owned_background() from public, anon, authenticated;
create trigger profiles_enforce_owned_background before insert or update of background_theme
on public.profiles for each row execute function private.enforce_owned_background();
