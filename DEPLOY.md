# Deploying Out Again

This is the shortest path from a fresh Supabase project to a running app
with the `1`/`1` developer shortcut working. Everything below assumes a
macOS shell with the [Supabase CLI](https://supabase.com/docs/guides/cli)
installed (`brew install supabase/tap/supabase`) and `curl` on your PATH.

## 1. Create the Supabase project

1. In the Supabase dashboard, create a new project.
2. Note the values you'll need under **Project Settings → API**:
   - `Project URL` (e.g. `https://abcd1234.supabase.co`)
   - `anon public` key (also called the publishable key)
   - `service_role` key (keep this secret — server-side use only)

Export them in your shell for the rest of this doc:

```sh
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_ANON_KEY="<anon public key>"
export SUPABASE_SERVICE_ROLE_KEY="<service_role key>"
```

## 2. Apply the database schema

From the repo root:

```sh
supabase link --project-ref <project-ref>
supabase db push
```

This applies every migration under `supabase/migrations/` in order. Verify
in the Dashboard that `profiles`, `friendships`, `posts`, `comments`,
`reactions`, `notifications`, `devices`, and `content_reports` all exist
under `public`, and that the `avatars` and `moments` storage buckets exist.

## 3. Enable Apple sign-in (optional, needed for App Store)

Project Settings → Authentication → Providers → Apple → enable. You do not
need to finish Apple provider config to run the `1`/`1` dev shortcut — it
uses email/password only.

## 4. Provision the developer test account

The in-app `1`/`1` shortcut no longer reads credentials from source control.
Pick any dev-only email/password pair you want, create that account once in
Supabase, and keep the credentials in local Xcode config only. There is no
server-side allowlist, so the account must actually exist. Create it with
the admin API:

```sh
curl -sS -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "<your-local-dev-email>",
    "password": "<your-local-dev-password>",
    "email_confirm": true
  }'
```

A `200` response with the new user's UUID means you're done. If you already
created the user and just want to reset the password, swap the method to
`PUT` and hit `/auth/v1/admin/users/<uuid>` with a body of
`{"password": "<your-local-dev-password>"}`.

To enable the `1`/`1` shortcut locally, set these on your machine only:

- Xcode scheme environment variables:
  `OUTAGAIN_DEV_SHORTCUT_EMAIL=<your-local-dev-email>`
  `OUTAGAIN_DEV_SHORTCUT_PASSWORD=<your-local-dev-password>`
- Or Info.plist/build settings with those same keys

Do not commit those values.

## 5. Deploy the edge functions

```sh
supabase functions deploy notify-activity
supabase functions deploy delete-account
supabase secrets set \
  APNS_KEY_ID="<10-char key ID from Apple Developer>" \
  APNS_TEAM_ID="<10-char team ID from Apple Developer>" \
  APNS_BUNDLE_ID="com.cristian.OutAgain" \
  APNS_ENVIRONMENT="production" \
  APNS_KEY_P8="$(cat AuthKey_<KEYID>.p8)"
```

> **Important:** The secret names above must match exactly. The edge function
> reads `APNS_KEY_P8` (not `APNS_AUTH_KEY`) and `APNS_ENVIRONMENT` (not
> `APNS_USE_SANDBOX`). Use `"development"` for Simulator/debug builds and
> `"production"` for TestFlight and App Store builds.

Then set the Postgres config values the `dispatch_notification_push` trigger
reads at runtime (run these in the Supabase SQL editor or via `psql`):

```sql
alter database postgres set app.settings.supabase_url = 'https://<project-ref>.supabase.co';
alter database postgres set app.settings.supabase_service_role_key = '<service_role key>';
```

Without these two settings, notification rows are still written but the edge
function is not called. Check `public.push_attempts`: the attempt will be
recorded as `skipped` with a `skip_reason` explaining the missing setting.

`delete-account` does not need APNs secrets. It only uses the standard
function environment (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`) to
verify the caller and remove the Auth user plus their Storage objects.

## 6. Configure the iOS target

In `OutAgain.xcodeproj`, open the OutAgain target's Info tab and add these
keys (or wire them through build settings). The app reads them from
`Bundle.main` at launch:

| Key                           | Value                                  |
| ----------------------------- | -------------------------------------- |
| `SUPABASE_URL`                | `$SUPABASE_URL` (your project URL)     |
| `SUPABASE_PUBLISHABLE_KEY`    | `$SUPABASE_ANON_KEY`                   |
| `SUPABASE_STORAGE_BUCKET`     | `moments` (optional; this is default)  |
| `SUPABASE_AVATAR_BUCKET`      | `avatars` (optional; this is default)  |
| `OUTAGAIN_INVITE_BASE_URL`    | `https://outagain.app/invite` (or yours) |
| `OUTAGAIN_DEV_SHORTCUT_EMAIL` | optional, local debug-only dev email   |
| `OUTAGAIN_DEV_SHORTCUT_PASSWORD` | optional, local debug-only dev password |

If `SUPABASE_URL` or `SUPABASE_PUBLISHABLE_KEY` are missing, the app
refuses to boot and shows a configuration-error screen. This is
deliberate — there is no mock fallback.

## 7. Enable push capabilities

1. In the OutAgain target, Signing & Capabilities → + → **Push
   Notifications**.
2. + → **Background Modes** → check **Remote notifications**.
3. Generate an APNs Auth Key in the Apple Developer portal and feed it into
   the edge function secrets above.

## 8. Run

Build and run in Debug. At the auth screen, type `1` in both fields and tap
continue. If your local machine has
`OUTAGAIN_DEV_SHORTCUT_EMAIL/PASSWORD` configured, the app intercepts `1`/`1`
before client-side validation, swaps in those local credentials, and calls
the real `POST /auth/v1/token?grant_type=password`. From there, every request
— profile creation, feed load, friendship mutations, reactions, comments,
notifications — runs against your real project.

The shortcut is compiled out in Release builds (`#if DEBUG` in
`DeveloperTestAccount.swift`). A shipped binary cannot log into the dev
account via `1`/`1`.

## Troubleshooting

**"Out Again isn't configured yet" on launch.** The Info.plist keys didn't
resolve. Check that the keys above are on the target's Info plist (not a
framework's), and that the build settings interpolating them aren't empty.

**`1`/`1` returns "Invalid login credentials."** The account either doesn't
exist in `auth.users`, or your local `OUTAGAIN_DEV_SHORTCUT_EMAIL/PASSWORD`
values don't match it. Re-run the curl in step 4 or reset the password with
the `PUT /auth/v1/admin/users/<uuid>` variant.

**Sign-in succeeds but the feed is empty.** That's correct on a fresh
project — the dev account has no friends and no posts yet. Create a second
account (any email/password via the normal sign-up flow), friend it, and
post from there.

**Pushes don't arrive.** Work through this checklist in order:
1. Check `public.push_attempts` for the newest row. `delivered` means APNs accepted it, `partial` means at least one device failed, `errored` means APNs rejected or could not be reached, and `skipped` means setup is incomplete.
2. Check the edge function logs (Dashboard → Edge Functions → notify-activity → Logs). If nothing appears, the trigger's `app.settings.*` Postgres config is not set — run the two `ALTER DATABASE` statements in step 5.
3. If logs show `Missing required env: APNS_KEY_P8` (or any `APNS_*` variable), re-run `supabase secrets set` with the correct names from step 5.
4. Confirm the device row environment matches your build: `"production"` for TestFlight and App Store, `"development"` for debug/Xcode installs.
5. Verify the `.entitlements` file has `aps-environment` set to `production` for distribution builds (Xcode adds this automatically when you enable the Push Notifications capability via Signing & Capabilities).

## Moderation queue

The easiest free moderation setup is the `public.content_reports` table.
Reports from the app land there with a snapshot of the reporter, the target,
and a short excerpt. Review them in Supabase Dashboard → Table Editor →
`content_reports`, usually filtered to `status = open` and sorted by
`created_at desc`.
