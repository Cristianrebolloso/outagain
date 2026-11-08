-- Migration 202605200010 granted column-level SELECT on profiles to
-- authenticated, but missed five columns the app reads:
--   is_banned, apple_user_identifier, ban_reason, banned_at, banned_by
--
-- Whenever a query SELECTs any of these (e.g. the fetchCurrentBanStatus
-- fallback issues `select id, is_banned from profiles`), postgres returns
-- "permission denied for table profiles" — not "for column" — because
-- column-level grants raise the table-level error when any requested column
-- is missing. The error surfaces on the welcome / sign-up screen because
-- it's caught at submitAuth and set on the global socialErrorMessage,
-- where it persists until the user toggles auth mode.
--
-- RLS on public.profiles still gates row visibility to
-- self/friends/requesters/admins (per migration 202605200010), so granting
-- column SELECT does NOT expose these fields to arbitrary signed-in users.
-- A viewer can only read these for rows they're already allowed to read.

grant select (
  is_banned,
  apple_user_identifier,
  ban_reason,
  banned_at,
  banned_by
) on table public.profiles to authenticated;
