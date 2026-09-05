#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/vultr.sh
source "$ROOT_DIR/scripts/lib/vultr.sh"

if [[ "${1:-}" == --help && "$#" == 1 ]]; then
  echo "Usage: $0"
  echo "Set VULTR_API_KEY, CREDIT_GUARD_DEADLINE, and optionally CREDIT_GUARD_DRY_RUN=1."
  exit 0
fi
if (($#)); then
  printf 'ERROR: Unknown argument; use --help.\n' >&2
  exit 2
fi

MIN_REMAINING="${CREDIT_GUARD_MIN_REMAINING:-1.00}"
LABEL_PREFIX="${CREDIT_GUARD_LABEL_PREFIX:-personal-vpn-}"
NOW_EPOCH="${CREDIT_GUARD_NOW_EPOCH:-$(date -u +%s)}"
DRY_RUN="${CREDIT_GUARD_DRY_RUN:-0}"
STATE_DIR="${CREDIT_GUARD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/personal-vpn-credit-guard}"
STATE_FILE="$STATE_DIR/status"
API="${CREDIT_GUARD_API:-https://api.vultr.com/v2}"
umask 077

log() {
  local line temporary
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line" >&2
  if [[ "$DRY_RUN" == 0 ]]; then
    mkdir -p "$STATE_DIR"
    temporary="$(mktemp "$STATE_DIR/status.XXXXXX")"
    printf '%s\n' "$line" >"$temporary"
    mv "$temporary" "$STATE_FILE"
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    if ! log "ERROR guard_aborted status=$status"; then
      printf 'ERROR: Could not persist guard failure status.\n' >&2
    fi
  fi
  exit "$status"
}
trap on_exit EXIT

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] ||
  vultr_error "CREDIT_GUARD_DRY_RUN must be 0 or 1"
[[ "$DRY_RUN" == 1 || -z "${CREDIT_GUARD_NOW_EPOCH+x}" ]] ||
  vultr_error "A simulated clock is only allowed in dry-run mode"
for command in curl python3 flock; do
  command -v "$command" >/dev/null 2>&1 || vultr_error "Missing command: $command"
done
validate_api_key
export -n VULTR_API_KEY
[[ "$LABEL_PREFIX" =~ ^personal-vpn-[A-Za-z0-9._-]*$ ]] ||
  vultr_error "CREDIT_GUARD_LABEL_PREFIX must stay inside the personal-vpn- namespace"
SETTINGS="$(vultr_json guard-settings "${CREDIT_GUARD_DEADLINE:-}" "$MIN_REMAINING" "$NOW_EPOCH")"
read -r DEADLINE_EPOCH MIN_REMAINING NOW_EPOCH <<<"$SETTINGS"

if [[ "$DRY_RUN" == 0 ]]; then
  mkdir -p "$STATE_DIR"
  exec {GUARD_LOCK_FD}>"$STATE_DIR/run.lock"
  flock -n "$GUARD_LOCK_FD" || vultr_error "Another credit guard is running"
fi

REASON=""
REMAINING="not_checked"
if (( NOW_EPOCH >= DEADLINE_EPOCH )); then
  REASON="deadline"
else
  ACCOUNT_JSON="$(api_get /account)"
  ACCOUNT_VALUES="$(vultr_json account <<<"$ACCOUNT_JSON")"
  read -r PENDING REMAINING <<<"$ACCOUNT_VALUES"
  EXHAUSTED="$(vultr_json credit-exhausted "$REMAINING" "$MIN_REMAINING")"
  [[ "$EXHAUSTED" != yes ]] || REASON="credit"
fi

if [[ -z "$REASON" ]]; then
  log "OK remaining_credit=$REMAINING pending_charges=$PENDING deadline=$CREDIT_GUARD_DEADLINE"
  exit 0
fi

INSTANCES_JSON="$(api_list /instances instances)"
TARGET_ROWS="$(
  python3 -c '
import json, sys
for item in json.load(sys.stdin)["instances"]:
    if item["label"].startswith(sys.argv[1]):
        print(item["id"] + "\t" + item["label"])
' "$LABEL_PREFIX" <<<"$INSTANCES_JSON"
)"
TARGETS=()
if [[ -n "$TARGET_ROWS" ]]; then
  mapfile -t TARGETS <<<"$TARGET_ROWS"
fi
if ((${#TARGETS[@]} == 0)); then
  log "TRIGGER reason=$REASON remaining_credit=$REMAINING no_matching_instances"
  exit 0
fi

for target in "${TARGETS[@]}"; do
  IFS=$'\t' read -r INSTANCE_ID LABEL <<<"$target"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY_RUN reason=$REASON would_destroy=$LABEL id=$INSTANCE_ID remaining_credit=$REMAINING"
  else
    delete_instance "$INSTANCE_ID"
    log "DESTROYED reason=$REASON label=$LABEL id=$INSTANCE_ID remaining_credit=$REMAINING"
  fi
done
