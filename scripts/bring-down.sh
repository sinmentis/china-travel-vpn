#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.vultr}"
API="${VULTR_API:-https://api.vultr.com/v2}"
# shellcheck source=scripts/lib/vultr.sh
source "$ROOT_DIR/scripts/lib/vultr.sh"
CONFIRMED=0
DRY_RUN=0
FORCE=0

for argument in "$@"; do
  case "$argument" in
    --yes) CONFIRMED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --help)
      echo "Usage: $0 [--dry-run] [--yes] [--force]"
      echo "Preview or permanently delete the configured managed instance."
      exit 0
      ;;
    *)
      echo "Usage: $0 [--dry-run] [--yes] [--force]" >&2
      exit 2
      ;;
  esac
done

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

remove_runtime_values() {
  local temporary
  temporary="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  awk '
    index($0, "VULTR_INSTANCE_ID=") != 1 &&
    index($0, "PRIMARY_IP=") != 1
  ' "$ENV_FILE" >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE"
for command in curl python3 flock; do
  command -v "$command" >/dev/null 2>&1 || die "Missing command: $command"
done
umask 077
if (( DRY_RUN == 0 )); then
  exec {ENV_LOCK_FD}>"$ENV_FILE.lock"
  flock -n "$ENV_LOCK_FD" || die "Another lifecycle operation is using $ENV_FILE"
fi
unset VULTR_API_KEY VULTR_INSTANCE_LABEL VULTR_INSTANCE_ID PRIMARY_IP
# shellcheck source=/dev/null
source "$ENV_FILE"
export -n VULTR_API_KEY
validate_api_key

LABEL="${VULTR_INSTANCE_LABEL:-personal-vpn-primary}"
STORED_INSTANCE_ID="${VULTR_INSTANCE_ID:-}"
[[ "$LABEL" =~ ^personal-vpn-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "Refusing to destroy a label outside the personal-vpn- namespace: $LABEL"
if [[ -n "$STORED_INSTANCE_ID" ]]; then
  vultr_json validate-id "$STORED_INSTANCE_ID" >/dev/null
fi
INSTANCES_JSON="$(api_list /instances instances)"
TARGET_ROWS="$(
  python3 -c '
import json, sys
label = sys.argv[1]
for instance in json.load(sys.stdin)["instances"]:
    if instance.get("label") == label:
        print(instance["id"] + "\t" + instance["main_ip"])
' "$LABEL" <<<"$INSTANCES_JSON"
)"
TARGETS=()
if [[ -n "$TARGET_ROWS" ]]; then
  mapfile -t TARGETS <<<"$TARGET_ROWS"
fi

if ((${#TARGETS[@]} == 0)); then
  if [[ -n "$STORED_INSTANCE_ID" && "$FORCE" == "0" ]]; then
    PRESENT="$(vultr_json has-instance "$STORED_INSTANCE_ID" <<<"$INSTANCES_JSON")"
    [[ "$PRESENT" == no ]] || die "Stored instance still exists with a different label; refusing cleanup"
  fi
  if (( DRY_RUN == 0 && CONFIRMED == 1 )); then
    remove_runtime_values
    rm -f "$ROOT_DIR/primary-ios.local.txt" "$ROOT_DIR/primary-ios.local.png"
  fi
  printf 'No instance named %s exists.\n' "$LABEL"
  exit 0
fi

((${#TARGETS[@]} == 1)) || die "More than one instance is named $LABEL"
IFS=$'\t' read -r INSTANCE_ID INSTANCE_IP <<<"${TARGETS[0]}"
if [[ -n "$STORED_INSTANCE_ID" && "$STORED_INSTANCE_ID" != "$INSTANCE_ID" &&
      "$FORCE" != "1" ]]; then
  die "Stored instance ID does not match Vultr. Inspect the target before using --force."
fi

if (( DRY_RUN == 1 )); then
  printf 'DRY_RUN would permanently destroy %s (%s).\n' "$LABEL" "$INSTANCE_IP"
  exit 0
fi

if (( CONFIRMED == 0 )); then
  [[ -t 0 ]] || die "Use --yes to confirm permanent destruction"
  read -rp "Permanently destroy $LABEL ($INSTANCE_IP)? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0
fi

delete_instance "$INSTANCE_ID"

if [[ -n "$INSTANCE_IP" ]] && command -v ssh-keygen >/dev/null 2>&1; then
  if ! ssh-keygen -R "$INSTANCE_IP" >/dev/null 2>&1; then
    printf 'WARNING: Could not remove the old SSH host-key entry.\n' >&2
  fi
fi
remove_runtime_values
rm -f "$ROOT_DIR/primary-ios.local.txt" "$ROOT_DIR/primary-ios.local.png"
printf 'Destroyed %s. Reusable SSH and REALITY credentials were kept.\n' "$LABEL"
