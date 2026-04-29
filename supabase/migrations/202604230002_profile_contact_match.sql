alter table if exists public.profiles
  add column if not exists normalized_email_hash text;

create unique index if not exists profiles_normalized_email_hash_unique_idx
  on public.profiles (normalized_email_hash)
  where normalized_email_hash is not null;
