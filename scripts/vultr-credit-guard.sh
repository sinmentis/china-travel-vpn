#!/usr/bin/env bash
set -Eeuo pipefail

# Required: VULTR_API_KEY and CREDIT_GUARD_DEADLINE.
: "${VULTR_API_KEY:?VULTR_API_KEY is required}"
: "${CREDIT_GUARD_DEADLINE:?CREDIT_GUARD_DEADLINE is required}"

MIN_REMAINING="${CREDIT_GUARD_MIN_REMAINING:-1.00}"
LABEL_PREFIX="${CREDIT_GUARD_LABEL_PREFIX:-personal-vpn-}"
NOW_EPOCH="${CREDIT_GUARD_NOW_EPOCH:-$(date -u +%s)}"
DRY_RUN="${CREDIT_GUARD_DRY_RUN:-0}"
STATE_DIR="${CREDIT_GUARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/personal-vpn-credit-guard}"
STATE_FILE="$STATE_DIR/status"
API="${CREDIT_GUARD_API:-https://api.vultr.com/v2}"

mkdir -p "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee "$STATE_FILE"
}

on_error() {
  local status=$?
  local line="$1"
  trap - ERR
  log "ERROR guard_aborted line=$line status=$status" || true
  exit "$status"
}

trap 'on_error "$LINENO"' ERR

get() {
  curl --fail-with-body -sS \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY") \
    "$API$1"
}

ACCOUNT_JSON="$(get /account)"
read -r PENDING REMAINING < <(
  python3 -c '
import decimal, json, sys
a = json.load(sys.stdin)["account"]
balance = decimal.Decimal(str(a["balance"]))
pending = decimal.Decimal(str(a["pending_charges"]))
remaining = max(decimal.Decimal("0"), -balance - pending)
print(pending, remaining)
' <<<"$ACCOUNT_JSON"
)

DEADLINE_EPOCH="$(date -u -d "$CREDIT_GUARD_DEADLINE" +%s)"
REASON=""

[[ "$LABEL_PREFIX" == personal-vpn-* ]] || {
  log "ERROR unsafe_label_prefix=$LABEL_PREFIX"
  exit 1
}

if (( NOW_EPOCH >= DEADLINE_EPOCH )); then
  REASON="deadline"
elif python3 -c 'import decimal,sys; raise SystemExit(0 if decimal.Decimal(sys.argv[1]) <= decimal.Decimal(sys.argv[2]) else 1)' \
  "$REMAINING" "$MIN_REMAINING"
then
  REASON="credit"
fi

if [[ -z "$REASON" ]]; then
  log "OK remaining_credit=$REMAINING pending_charges=$PENDING deadline=$CREDIT_GUARD_DEADLINE"
  exit 0
fi

INSTANCES_JSON="$(get '/instances?per_page=500')"
mapfile -t TARGETS < <(
  python3 -c '
import json, sys
prefix = sys.argv[1]
for instance in json.load(sys.stdin)["instances"]:
    label = instance.get("label", "")
    if label.startswith(prefix):
        print(instance["id"] + "\t" + label)
' "$LABEL_PREFIX" <<<"$INSTANCES_JSON"
)

if ((${#TARGETS[@]} == 0)); then
  log "TRIGGER reason=$REASON remaining_credit=$REMAINING no_matching_instances"
  exit 0
fi

for target in "${TARGETS[@]}"; do
  IFS=$'\t' read -r INSTANCE_ID LABEL <<<"$target"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN reason=$REASON would_destroy=$LABEL id=$INSTANCE_ID remaining_credit=$REMAINING"
    continue
  fi

  HTTP_CODE="$(
    curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY") \
      "$API/instances/$INSTANCE_ID"
  )"
  if [[ "$HTTP_CODE" != "204" ]]; then
    log "ERROR destroy_failed=$LABEL id=$INSTANCE_ID http=$HTTP_CODE"
    exit 1
  fi
  log "DESTROYED reason=$REASON label=$LABEL id=$INSTANCE_ID remaining_credit=$REMAINING"
done
