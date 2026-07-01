#!/usr/bin/env bash
# =============================================================================
# test-webhook.sh — webhook Integration Test
#
# Verifies the full webhook sync pipeline:
#   Track BE (create) → Logistics BE (mirror + status update)
#     → webhook fires → Track BE (assert updated status)
#
# Prerequisites:
#   - Both backends running:
#       courier-track-be    on http://localhost:3001
#       courier-logistics-be on http://localhost:3002
#   - Both DBs seeded (regions + users exist)
#   - jq installed: sudo apt install jq / brew install jq
#
# Usage:
#   chmod +x scripts/test-webhook.sh
#   ./scripts/test-webhook.sh
# =============================================================================

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

TRACK_URL="http://localhost:3001"
LOGISTICS_URL="http://localhost:3002"

# Seeded credentials (from courier-track-be/prisma/seed.ts)
TRACK_ADMIN_EMAIL="admin@couriertrack.com"
TRACK_ADMIN_PASS="admin123"
LOGISTICS_EMAIL="logistics@couriertrack.com"
LOGISTICS_PASS="logistics123"

# How long to wait (seconds) after the status update for the webhook to deliver
WEBHOOK_WAIT=2

# ─── Colours ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

step() { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }
ok()   { echo -e "  ${GREEN}✅ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${RESET}"; }
fail() { echo -e "  ${RED}❌ $*${RESET}"; exit 1; }

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label: \"$actual\""
  else
    fail "$label mismatch — expected \"$expected\", got \"$actual\""
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."
}

# ─── Preflight checks ─────────────────────────────────────────────────────────

require_cmd curl
require_cmd jq

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Webhook Sync Integration Test${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# ─── Step 1: Health-check both backends ──────────────────────────────────────

step "Step 1/8 — Health-check backends"

TRACK_HEALTH=$(curl -sf "$TRACK_URL/" || true)
[ -n "$TRACK_HEALTH" ] && ok "Track BE is up ($TRACK_URL)" \
  || fail "Track BE is not responding at $TRACK_URL — is it running?"

LOGISTICS_HEALTH=$(curl -sf "$LOGISTICS_URL/" || true)
[ -n "$LOGISTICS_HEALTH" ] && ok "Logistics BE is up ($LOGISTICS_URL)" \
  || fail "Logistics BE is not responding at $LOGISTICS_URL — is it running?"

# ─── Step 2: Login to Track BE (staff token) ─────────────────────────────────

step "Step 2/8 — Login to Track BE as staff/admin"

TRACK_LOGIN=$(curl -sf -X POST "$TRACK_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TRACK_ADMIN_EMAIL\",\"password\":\"$TRACK_ADMIN_PASS\"}")

TRACK_TOKEN=$(echo "$TRACK_LOGIN" | jq -r '.token // .data.token // empty')
[ -n "$TRACK_TOKEN" ] && ok "Got Track BE JWT" \
  || fail "Login to Track BE failed. Response: $TRACK_LOGIN"

# ─── Step 3: Login to Logistics BE ───────────────────────────────────────────

step "Step 3/8 — Login to Logistics BE as logistics operator"

LOGISTICS_LOGIN=$(curl -sf -X POST "$LOGISTICS_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$LOGISTICS_EMAIL\",\"password\":\"$LOGISTICS_PASS\"}")

LOGISTICS_TOKEN=$(echo "$LOGISTICS_LOGIN" | jq -r '.token // .data.token // empty')
[ -n "$LOGISTICS_TOKEN" ] && ok "Got Logistics BE JWT" \
  || fail "Login to Logistics BE failed. Response: $LOGISTICS_LOGIN"

# ─── Step 4: Get a region ID from Track BE ───────────────────────────────────

step "Step 4/8 — Fetch a region from Track BE"

TRACK_REGIONS=$(curl -sf "$TRACK_URL/api/regions" \
  -H "Authorization: Bearer $TRACK_TOKEN")

TRACK_REGION_ID=$(echo "$TRACK_REGIONS" | jq -r '.[0].id // empty')
TRACK_REGION_CODE=$(echo "$TRACK_REGIONS" | jq -r '.[0].regionCode // empty')

[ -n "$TRACK_REGION_ID" ] && ok "Track region: $TRACK_REGION_CODE ($TRACK_REGION_ID)" \
  || fail "No regions found in Track BE — have you run the seed?"

# ─── Step 5: Get a region ID from Logistics BE ───────────────────────────────

step "Step 5/8 — Fetch a matching region from Logistics BE"

# Prefer the same regionCode so the mirror is consistent
LOGISTICS_REGIONS=$(curl -sf "$LOGISTICS_URL/api/regions")

LOGISTICS_REGION_ID=$(echo "$LOGISTICS_REGIONS" | jq -r \
  --arg code "$TRACK_REGION_CODE" \
  '[.[] | select(.regionCode == $code)] | .[0].id // empty')

if [ -z "$LOGISTICS_REGION_ID" ]; then
  # Fallback: any region
  LOGISTICS_REGION_ID=$(echo "$LOGISTICS_REGIONS" | jq -r '.[0].id // empty')
  LOGISTICS_REGION_CODE=$(echo "$LOGISTICS_REGIONS" | jq -r '.[0].regionCode // empty')
  warn "No matching region for $TRACK_REGION_CODE; using $LOGISTICS_REGION_CODE instead"
else
  ok "Logistics region: $TRACK_REGION_CODE ($LOGISTICS_REGION_ID)"
fi

[ -n "$LOGISTICS_REGION_ID" ] || fail "No regions found in Logistics BE — have you run the seed?"

# ─── Step 6: Create a package in Track BE ────────────────────────────────────

step "Step 6/8 — Create package in Track BE (source of truth)"

CREATE_RESPONSE=$(curl -sf -X POST "$TRACK_URL/api/packages" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TRACK_TOKEN" \
  -d "{
    \"senderName\":    \"Test Sender\",
    \"senderAddress\": \"123 Origin St, Bangkok\",
    \"receiverName\":  \"Test Receiver\",
    \"receiverAddress\": \"456 Dest Ave, Chiang Mai\",
    \"weightKg\":      2.5,
    \"regionId\":      \"$TRACK_REGION_ID\",
    \"paymentMethod\": \"cash\"
  }")

TRACKING_ID=$(echo "$CREATE_RESPONSE" | jq -r '.trackingId // empty')
BILL_NUMBER=$(echo "$CREATE_RESPONSE" | jq -r '.billNumber // empty')

[ -n "$TRACKING_ID" ] && ok "Package created — trackingId: $TRACKING_ID | bill: $BILL_NUMBER" \
  || fail "Package creation in Track BE failed. Response: $CREATE_RESPONSE"

echo -e "    ${YELLOW}trackingId: $TRACKING_ID${RESET}"

# ─── Step 7: Mirror the package in Logistics BE ──────────────────────────────

step "Step 7/8 — Mirror package in Logistics BE"

LOGISTICS_CREATE=$(curl -sf -X POST "$LOGISTICS_URL/api/packages" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LOGISTICS_TOKEN" \
  -d "{
    \"trackingId\":      \"$TRACKING_ID\",
    \"senderName\":      \"Test Sender\",
    \"senderAddress\":   \"123 Origin St, Bangkok\",
    \"receiverName\":    \"Test Receiver\",
    \"receiverAddress\": \"456 Dest Ave, Chiang Mai\",
    \"weightKg\":        2.5,
    \"originRegionId\":  \"$LOGISTICS_REGION_ID\",
    \"destRegionId\":    \"$LOGISTICS_REGION_ID\",
    \"currentRegionId\": \"$LOGISTICS_REGION_ID\"
  }")

LOGISTICS_PKG_ID=$(echo "$LOGISTICS_CREATE" | jq -r '.data.id // empty')
LOGISTICS_INIT_STATUS=$(echo "$LOGISTICS_CREATE" | jq -r '.data.currentStatus // empty')

[ -n "$LOGISTICS_PKG_ID" ] && ok "Mirrored in Logistics BE — id: $LOGISTICS_PKG_ID | status: $LOGISTICS_INIT_STATUS" \
  || fail "Package mirror in Logistics BE failed. Response: $LOGISTICS_CREATE"

# ─── Step 8: Update status + wait for webhook → assert Track BE ──────────────

step "Step 8/8 — Update status to 'picked_up' in Logistics BE → assert Track BE"

UPDATE_RESPONSE=$(curl -sf -X PATCH "$LOGISTICS_URL/api/packages/$LOGISTICS_PKG_ID/status" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LOGISTICS_TOKEN" \
  -d "{
    \"status\": \"picked_up\",
    \"notes\":  \"Package collected from sender\"
  }")

NEW_LOGISTICS_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.data.currentStatus // empty')
ok "Logistics BE status updated → $NEW_LOGISTICS_STATUS"
echo -e "  ${YELLOW}↩  Waiting ${WEBHOOK_WAIT}s for webhook delivery...${RESET}"
sleep "$WEBHOOK_WAIT"

# Query Track BE — status should now be 'picked_up' (direct map)
TRACK_PKG=$(curl -sf -X POST "$TRACK_URL/api/tracking" \
  -H "Content-Type: application/json" \
  -d "{\"trackingId\":\"$TRACKING_ID\",\"captchaToken\":\"test\"}")

TRACK_STATUS=$(echo "$TRACK_PKG" | jq -r '.currentStatus // empty')
assert_eq "Track BE status after webhook" "$TRACK_STATUS" "picked_up"

# ─── Bonus: test status mapping (in_transit via added_to_bag) ────────────────

echo ""
echo -e "  ${CYAN}--- Bonus: testing status mapping (added_to_bag → in_transit) ---${RESET}"

curl -sf -X PATCH "$LOGISTICS_URL/api/packages/$LOGISTICS_PKG_ID/status" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LOGISTICS_TOKEN" \
  -d "{\"status\":\"added_to_bag\"}" > /dev/null

sleep "$WEBHOOK_WAIT"

TRACK_PKG2=$(curl -sf -X POST "$TRACK_URL/api/tracking" \
  -H "Content-Type: application/json" \
  -d "{\"trackingId\":\"$TRACKING_ID\",\"captchaToken\":\"test\"}")

TRACK_STATUS2=$(echo "$TRACK_PKG2" | jq -r '.currentStatus // empty')
assert_eq "Track BE status (added_to_bag→in_transit mapping)" "$TRACK_STATUS2" "in_transit"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  All assertions passed — webhook sync is working ✅${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Verified flow:"
echo -e "  Track BE create → Logistics BE mirror"
echo -e "  Logistics PATCH /status → webhook fires → Track BE updated"
echo -e ""
echo -e "  ${YELLOW}Cleanup: the test package (trackingId: $TRACKING_ID) remains in both DBs.${RESET}"
echo -e "  ${YELLOW}You can delete it manually or re-run the seed if needed.${RESET}"
