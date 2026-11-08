# Deploying Out Again

This is the production deployment checklist for Out Again 2.2. It takes a
fresh Supabase project to a real backend that can support App Store users:
auth, friend-only data access, push delivery, account deletion, reports, and
admin moderation. Everything below assumes a macOS shell with the
[Supabase CLI](https://supabase.com/docs/guides/cli) installed
(`brew install supabase/tap/supabase`) and `curl` on your PATH.

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

## 3. Enable Apple sign-in

Project Settings → Authentication → Providers → Apple → enable. For the
shipping app, finish the Apple provider setup with the Services ID, Team ID,
Key ID, and private key from the Apple Developer portal.

## 4. Provision review and operations accounts

Create the accounts you need before submitting the app: the App Review
account, the `@admin` moderation account, and any local-only debug account
you use while developing. Keep passwords out of source control. Create each
email/password account with the admin API:

```sh
curl -sS -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "<account-email>",
    "password": "<account-password>",
    "email_confirm": true
  }'
```

A `200` response with the new user's UUID means the account exists. If you
already created the user and just want to reset the password, swap the method
to `PUT` and hit `/auth/v1/admin/users/<uuid>` with a body of
`{"password": "<account-password>"}`.

The `@admin` account is identified by username in the database moderation
RPCs, so complete profile onboarding for that account and claim the username
`admin`. App Review/demo accounts should stay available so Apple can exercise
the social graph, reports, comments, posts, groups, and account controls.

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
> `"production"` for distributed Release and App Store builds.

Then set the Postgres config values the `dispatch_notification_push` trigger
reads at runtime. Hosted Supabase no longer supports this flow reliably for
arbitrary `app.settings.*` keys, so use Supabase Vault instead:

```sql
select vault.create_secret(
  '<service_role key>',
  'supabase_service_role_key',
  'Out Again push trigger service-role key'
);
```

If the secret already exists, update it instead:

```sql
select vault.update_secret(
  (
    select id
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1
  ),
  '<service_role key>',
  'supabase_service_role_key',
  'Out Again push trigger service-role key'
);
```

Without that Vault secret, notification rows are still written but the edge
function is not called. Check `public.push_attempts`: the attempt will be
recorded as `skipped` with a `skip_reason` explaining the missing secret.

`delete-account` does not need APNs secrets. It only uses the standard
function environment (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`) to
verify the caller and remove the Auth user plus their Storage objects.

## 6. Configure the iOS target

In `OutAgain.xcodeproj`, the OutAgain target should point at the production
Supabase project. The current project includes production publishable defaults,
and these Info.plist/build-setting keys can override them when needed:

| Key                           | Value                                  |
| ----------------------------- | -------------------------------------- |
| `SUPABASE_URL`                | `$SUPABASE_URL` (your project URL)     |
| `SUPABASE_PUBLISHABLE_KEY`    | `$SUPABASE_ANON_KEY`                   |
| `SUPABASE_STORAGE_BUCKET`     | `moments` (optional; this is default)  |
| `SUPABASE_AVATAR_BUCKET`      | `avatars` (optional; this is default)  |
| `OUTAGAIN_INVITE_BASE_URL`    | `https://outagain.app/invite` (or yours) |
| `OUTAGAIN_DEV_SHORTCUT_EMAIL` | optional, local debug-only email       |
| `OUTAGAIN_DEV_SHORTCUT_PASSWORD` | optional, local debug-only password |

The anon/publishable key is safe to include in the app bundle. Never include
the service-role key in the app; it belongs only in Supabase Edge Function
secrets and Vault.

## Maintenance mode

After migrations are applied, `public.app_config` gives you a remote shutdown
switch. Flip it from the Supabase SQL editor when you need backend maintenance;
no App Store update is required.

```sql
insert into public.app_config (key, value)
values
  ('maintenance_mode_enabled', 'true'),
  ('maintenance_title', 'Out Again is currently unavailable'),
  ('maintenance_message', 'We''re doing some quick maintenance. Please check back soon.')
on conflict (key) do update
set value = excluded.value;
```

Bring the app back:

```sql
update public.app_config
set value = 'false'
where key = 'maintenance_mode_enabled';
```

## 7. Enable push capabilities

1. In the OutAgain target, Signing & Capabilities → + → **Push
   Notifications**.
2. + → **Background Modes** → check **Remote notifications**.
3. Generate an APNs Auth Key in the Apple Developer portal and feed it into
   the edge function secrets above.

## 8. Run and validate

Build and run a Release configuration pointed at the production Supabase
project. Verify sign-up/sign-in, profile onboarding, posting, comments,
reactions, friend requests, blocking, reporting, account deletion, admin
moderation, and push delivery against the real backend.

For local Debug builds only, you can enable the `1`/`1` auth shortcut by
setting `OUTAGAIN_DEV_SHORTCUT_EMAIL` and
`OUTAGAIN_DEV_SHORTCUT_PASSWORD` as scheme environment variables or local
Info.plist/build settings. The shortcut is compiled out in Release builds
(`#if DEBUG` in `DeveloperTestAccount.swift`), and a shipped binary cannot
log into that account via `1`/`1`.

## Username sign-in and passkeys

Sign In accepts a username, an optional `@username`, or an email address.
Username matching ignores case and surrounding whitespace. Sign Up still
requires an email address. Password AutoFill uses the username content type
on the sign-in screen.

The `sign-in` Edge Function resolves the username using server-only credentials
and verifies the supplied password with Supabase Auth. It returns a session only
after successful password verification. Unknown usernames and wrong passwords
return the same error. The database counter and RPC are inaccessible to `anon`
and `authenticated`, with atomic limits of 20 attempts per username and 60 per
IP per five minutes. Supabase Auth's own limits also apply. The function must
have `verify_jwt = false` because it authenticates signed-out users itself.

Deploy the `username_signin_rate_limits` migration before deploying `sign-in`:

```sh
supabase functions deploy sign-in --project-ref xissvzlusznqpxvwnwpu --no-verify-jwt
node --experimental-strip-types --test supabase/functions/sign-in/index.test.mjs
```

The app also implements native passkey registration, sign-in, listing, and
removal using AuthenticationServices and Supabase's two-step WebAuthn API.
Passkeys are hidden until the public `app_config.passkeys_enabled` flag is
`true`. Keep the flag off until every setup step below is complete.

1. Host `docs/.well-known/apple-app-site-association` at
   `https://outagain.app/.well-known/apple-app-site-association`. It must return
   HTTP 200 with `application/json`, without a redirect. The supplied file
   authorizes `4JLZS37N8V.com.cristian.OutAgain`. If using GitHub Pages, publish
   the `docs` folder with `.nojekyll` and configure the custom domain and HTTPS.
   Registrar URL forwarding alone cannot serve this file.
2. Enable Associated Domains for `com.cristian.OutAgain` in Apple Developer
   and regenerate provisioning profiles. Both app entitlement files already
   include `webcredentials:outagain.app`. Install a newly signed build.
3. In Supabase → Authentication → Passkeys, enable passkeys with display name
   `Out Again`, relying party ID `outagain.app`, and origin
   `https://outagain.app`. Keep this ID stable after users enroll. Supabase's
   passkey API is currently experimental; verify it before upgrading services.
4. Enable the entry points:

   ```sql
   insert into public.app_config (key, value)
   values ('passkeys_enabled', 'true')
   on conflict (key) do update set value = excluded.value;
   ```

5. On a real iPhone, sign in with a password and open Profile → Settings →
   Passkeys → Add a Passkey. Verify enrollment, canceling the system sheet,
   signing out, signing in with the saved passkey, and removing it. A canceled
   sheet must leave the user signed out without showing a failure. Password
   sign-in must continue to work after removing the last passkey.

`OUTAGAIN_PASSKEY_RP_ID` can override the client relying party ID for other
environments; update both entitlement files, website association, and Supabase
configuration together. No secret or service-role key belongs in the app.

### Troubleshooting

**"Out Again isn't configured yet" on launch.** The build is pointing at
placeholder Supabase values. Check that the target uses the production build
settings or valid override keys, not `replace-me` placeholders.

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
2. Check the edge function logs (Dashboard → Edge Functions → notify-activity → Logs). If nothing appears, the trigger likely cannot read the `supabase_service_role_key` Vault secret — create or update that secret using the Vault step above.
3. If logs show `Missing required env: APNS_KEY_P8` (or any `APNS_*` variable), re-run `supabase secrets set` with the correct names from step 5.
4. Confirm the device row environment matches your build: `"production"` for distributed Release and App Store builds, `"development"` for debug/Xcode installs.
5. Verify the `.entitlements` file has `aps-environment` set to `production` for distribution builds (Xcode adds this automatically when you enable the Push Notifications capability via Signing & Capabilities).

## Moderation queue

The easiest free moderation setup is the `public.content_reports` table.
Reports from the app land there with a snapshot of the reporter, the target,
and a short excerpt. Review them in Supabase Dashboard → Table Editor →
`content_reports`, usually filtered to `status = open` and sorted by
`created_at desc`.
