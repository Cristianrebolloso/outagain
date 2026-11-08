-- Contacts discovery has been removed from the product. Drop the matching RPC
-- and the stored email fingerprint column so new deployments do not retain
-- contact-matching infrastructure.

drop function if exists public.match_profiles_by_email_hashes(text[]);

drop index if exists public.profiles_normalized_email_hash_unique_idx;

alter table if exists public.profiles
  drop column if exists normalized_email_hash;
