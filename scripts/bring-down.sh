#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.vultr}"
API="${VULTR_API:-https://api.vultr.com/v2}"
CONFIRMED=0
DRY_RUN=0
FORCE=0

for argument in "$@"; do
  case "$argument" in
    --yes) CONFIRMED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
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

api_get() {
  curl --fail-with-body -sS \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY") \
    "$API$1"
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
unset VULTR_API_KEY VULTR_INSTANCE_LABEL VULTR_INSTANCE_ID PRIMARY_IP
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
: "${VULTR_API_KEY:?VULTR_API_KEY is required}"

LABEL="${VULTR_INSTANCE_LABEL:-personal-vpn-primary}"
STORED_INSTANCE_ID="${VULTR_INSTANCE_ID:-}"
[[ "$LABEL" == personal-vpn-* ]] ||
  die "Refusing to destroy a label outside the personal-vpn- namespace: $LABEL"
INSTANCES_JSON="$(api_get '/instances?per_page=500')"
mapfile -t TARGETS < <(
  python3 -c '
import json, sys
label = sys.argv[1]
for instance in json.load(sys.stdin)["instances"]:
    if instance.get("label") == label:
        print(instance["id"] + "\t" + instance["main_ip"])
' "$LABEL" <<<"$INSTANCES_JSON"
)

if ((${#TARGETS[@]} == 0)); then
  remove_runtime_values
  rm -f "$ROOT_DIR/primary-ios.local.txt" "$ROOT_DIR/primary-ios.local.png"
  printf 'No instance named %s exists.\n' "$LABEL"
  exit 0
fi

((${#TARGETS[@]} == 1)) || die "More than one instance is named $LABEL"
IFS=$'\t' read -r INSTANCE_ID INSTANCE_IP <<<"${TARGETS[0]}"
if [[ -n "$STORED_INSTANCE_ID" && "$STORED_INSTANCE_ID" != "$INSTANCE_ID" &&
      "$FORCE" != "1" ]]; then
  die "Stored instance ID does not match Vultr. Run bring-up --verify-only or use --force."
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

HTTP_CODE="$(
  curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY") \
    "$API/instances/$INSTANCE_ID"
)"
[[ "$HTTP_CODE" == "204" ]] || die "Vultr returned HTTP $HTTP_CODE"

for _ in $(seq 1 60); do
  INSTANCES_JSON="$(api_get '/instances?per_page=500')"
  COUNT="$(
    python3 -c '
import json, sys
label = sys.argv[1]
print(sum(item.get("label") == label for item in json.load(sys.stdin)["instances"]))
' "$LABEL" <<<"$INSTANCES_JSON"
  )"
  [[ "$COUNT" == "0" ]] && break
  sleep 5
done
[[ "$COUNT" == "0" ]] || die "Instance deletion did not complete"

ssh-keygen -R "$INSTANCE_IP" >/dev/null 2>&1 || true
remove_runtime_values
rm -f "$ROOT_DIR/primary-ios.local.txt" "$ROOT_DIR/primary-ios.local.png"
printf 'Destroyed %s. Reusable SSH and REALITY credentials were kept.\n' "$LABEL"
