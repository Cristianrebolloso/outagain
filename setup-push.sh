#!/usr/bin/env bash
# setup-push.sh — one-shot push notification deployment for Out Again
#
# Run this from the repo root once you have your APNs .p8 key from Apple.
# It will:
#   1. Walk you through getting the APNs key if you haven't yet
#   2. Deploy the notify-activity edge function
#   3. Set all required Supabase secrets with the correct names
#   4. Configure the Postgres trigger settings so it calls the edge function
#
# Prerequisites:
#   - Supabase CLI installed: brew install supabase/tap/supabase
#   - Logged in to Supabase CLI: supabase login
#   - psql available (comes with Postgres, or: brew install libpq)

set -euo pipefail

# ── Known values (read from your project) ─────────────────────────────────────
SUPABASE_PROJECT_REF="xissvzlusznqpxvwnwpu"
SUPABASE_URL="https://xissvzlusznqpxvwnwpu.supabase.co"
BUNDLE_ID="com.cristian.OutAgain"

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${BOLD}▶ $1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
die()  { echo -e "\n${RED}✗ $1${NC}\n" >&2; exit 1; }

echo ""
echo -e "${BOLD}Out Again — Push Notification Setup${NC}"
echo "────────────────────────────────────────"

# ── Step 1: APNs key instructions ─────────────────────────────────────────────
step "Get your APNs Auth Key from Apple Developer"
cat <<'EOF'

  You need an APNs key (.p8 file) from the Apple Developer portal.
  This is a one-time step — the key works for all your apps and never expires.

  1. Go to: https://developer.apple.com/account/resources/authkeys/list
  2. Click the blue (+) button to create a new key
  3. Name it (e.g. "Out Again Push") and check "Apple Push Notifications service (APNs)"
  4. Click Continue → Register → Download Key File
     ⚠  Save the .p8 file — Apple will only let you download it once.
  5. Note the Key ID shown on the page (10 characters, looks like ABC123DEF4)
  6. Your Team ID is at: https://developer.apple.com/account (top right, 10 chars)

EOF

read -rp "  Full path to your AuthKey_XXXXXXXXXX.p8 file: " P8_PATH
[[ -f "$P8_PATH" ]] || die "File not found: $P8_PATH"

read -rp "  Key ID (10 chars, from the portal): " KEY_ID
[[ ${#KEY_ID} -eq 10 ]] || warn "Key ID is usually exactly 10 characters — double-check this."

read -rp "  Team ID (10 chars, from developer.apple.com/account): " TEAM_ID
[[ ${#TEAM_ID} -eq 10 ]] || warn "Team ID is usually exactly 10 characters — double-check this."

ok "APNs credentials collected."

# ── Step 2: service role key ───────────────────────────────────────────────────
step "Supabase service role key"
cat <<'EOF'

  Find this at: https://supabase.com/dashboard/project/xissvzlusznqpxvwnwpu/settings/api
  It's the "service_role" key (secret — never put this in the app).

EOF
read -rsp "  Paste service_role key (input hidden): " SERVICE_ROLE_KEY
echo ""
[[ -n "$SERVICE_ROLE_KEY" ]] || die "Service role key cannot be empty."
ok "Service role key collected."

# ── Step 3: Link project ───────────────────────────────────────────────────────
step "Linking Supabase CLI to your project"
supabase link --project-ref "$SUPABASE_PROJECT_REF" || die "supabase link failed. Make sure you ran: supabase login"
ok "Linked to project $SUPABASE_PROJECT_REF."

# ── Step 4: Deploy edge function ───────────────────────────────────────────────
step "Deploying notify-activity edge function"
supabase functions deploy notify-activity
ok "Edge function deployed."

# ── Step 5: Set secrets (correct names matching index.ts) ─────────────────────
step "Setting Supabase secrets"
P8_CONTENTS="$(cat "$P8_PATH")"
supabase secrets set \
  APNS_KEY_ID="$KEY_ID" \
  APNS_TEAM_ID="$TEAM_ID" \
  APNS_BUNDLE_ID="$BUNDLE_ID" \
  APNS_ENVIRONMENT="production" \
  APNS_KEY_P8="$P8_CONTENTS"
ok "Secrets set: APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_ENVIRONMENT, APNS_KEY_P8."

# ── Step 6: Set Postgres trigger config ───────────────────────────────────────
step "Configuring Postgres trigger settings"
cat <<EOF

  The dispatch_notification_push trigger reads two Postgres settings at
  runtime to know where to POST. Setting them now via the Management API.

EOF

EDGE_FN_URL="$SUPABASE_URL/functions/v1/notify-activity"

# Use the Supabase Management API to run SQL
SQL="ALTER DATABASE postgres SET app.settings.supabase_url = '$SUPABASE_URL'; ALTER DATABASE postgres SET app.settings.supabase_service_role_key = '$SERVICE_ROLE_KEY';"

RESPONSE=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$SUPABASE_URL/rest/v1/rpc/exec_sql" \
  -H "apikey: $SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"$(echo "$SQL" | tr -d '\n' | sed 's/"/\\"/g')\"}" 2>/dev/null || true)

# The above may not work if exec_sql RPC doesn't exist — provide manual fallback
if [[ "$RESPONSE" != "200" ]]; then
  warn "Automatic Postgres config failed (this is normal if exec_sql RPC isn't set up)."
  echo ""
  echo -e "  ${BOLD}Run this SQL manually in the Supabase SQL editor:${NC}"
  echo "  https://supabase.com/dashboard/project/$SUPABASE_PROJECT_REF/sql/new"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────────────┐"
  echo "  │ ALTER DATABASE postgres                                              │"
  echo "  │   SET app.settings.supabase_url = '$SUPABASE_URL';     │"
  echo "  │                                                                     │"
  echo "  │ ALTER DATABASE postgres                                              │"
  echo "  │   SET app.settings.supabase_service_role_key = '<your key>';        │"
  echo "  └─────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Replace <your key> with your service_role key (the one you pasted above)."
  echo ""
  read -rp "  Press Enter once you've run the SQL above... "
else
  ok "Postgres trigger settings configured."
fi

# ── Step 7: Verify ────────────────────────────────────────────────────────────
step "Verification"
echo ""
echo "  Everything should now be wired up. To confirm it works end-to-end:"
echo ""
echo "  1. Build and install the app on a real device via TestFlight or Xcode"
echo "  2. Sign in and grant notification permissions"
echo "  3. In the app, use the debug self-test: tap Profile → (any debug button"
echo "     that calls sendSelfTestNotification()) — or trigger a follow/like/comment"
echo "     from another account"
echo "  4. Check public.push_attempts in the Supabase SQL editor."
echo "     A successful push ends with status='delivered' and delivered_count > 0."
echo "  5. Check edge function logs:"
echo "     https://supabase.com/dashboard/project/$SUPABASE_PROJECT_REF/functions/notify-activity"
echo ""
echo "  If push_attempts shows delivered_count > 0 — you're done. Notifications are live."
echo ""
echo -e "${GREEN}${BOLD}Setup complete.${NC}"
echo ""
