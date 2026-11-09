-- Retire dislike writes while preserving existing history for older clients.
-- NOT VALID exempts existing rows; PostgreSQL still checks every new/updated row.
alter table public.reactions
  add constraint reactions_no_new_dislikes
  check (kind <> 'dislike') not valid;
