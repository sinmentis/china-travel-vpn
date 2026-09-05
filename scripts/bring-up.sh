#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.vultr}"
API="${VULTR_API:-https://api.vultr.com/v2}"
# shellcheck source=scripts/lib/vultr.sh
source "$ROOT_DIR/scripts/lib/vultr.sh"
XRAY_INSTALLER_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
XRAY_INSTALLER_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
VERIFY_ONLY=0
EXPORT_CLIENT=0

for argument in "$@"; do
  case "$argument" in
    --verify-only) VERIFY_ONLY=1 ;;
    --export-client) EXPORT_CLIENT=1 ;;
    --help)
      echo "Usage: $0 [--verify-only [--export-client]]"
      echo "Deploy the configured instance, or verify it without changing persistent state."
      exit 0
      ;;
    *)
      echo "Usage: $0 [--verify-only [--export-client]]" >&2
      exit 2
      ;;
  esac
done
if (( EXPORT_CLIENT == 1 && VERIFY_ONLY == 0 )); then
  echo "ERROR: --export-client requires --verify-only; deployment already exports the client." >&2
  exit 2
fi

log() {
  STAGE="$*"
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

validate_reality_credentials() {
  [[ "${REALITY_PRIVATE_KEY:-}" =~ ^[A-Za-z0-9_-]{43}$ ]] ||
    die "REALITY_PRIVATE_KEY is invalid"
  [[ "${REALITY_PUBLIC_KEY:-}" =~ ^[A-Za-z0-9_-]{43}$ ]] ||
    die "REALITY_PUBLIC_KEY is invalid"
  [[ "${VPN_UUID:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    die "VPN_UUID is invalid"
  [[ "${REALITY_SHORT_ID:-}" =~ ^[0-9A-Fa-f]{16}$ ]] ||
    die "REALITY_SHORT_ID is invalid"
}

set_env() {
  (( VERIFY_ONLY == 0 )) || die "Refusing to write settings during verification"
  local key="$1"
  local value="$2"
  local temporary
  temporary="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  awk -v key="$key" 'index($0, key "=") != 1' "$ENV_FILE" >"$temporary"
  printf '%s=%q\n' "$key" "$value" >>"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ENV_FILE"
}

wait_for_ssh() {
  local user="$1"
  for _ in $(seq 1 60); do
    if ssh "${SSH_OPTIONS[@]}" "$user@$PRIMARY_IP" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "SSH did not become ready for $user@$PRIMARY_IP"
}

test_reality_client() {
  local architecture asset metadata url digest directory binary port egress
  case "$(uname -m)" in
    x86_64) architecture="amd64" ;;
    aarch64 | arm64) architecture="arm64" ;;
    *) die "Unsupported local architecture for client test: $(uname -m)" ;;
  esac

  asset="sing-box-1.14.0-linux-${architecture}.tar.gz"
  directory="$RUN_DIR/client"
  mkdir -m 700 "$directory"
  metadata="$(
    curl -qfsS --connect-timeout 10 --max-time 60 https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.14.0 |
      python3 -c '
import json, sys
name = sys.argv[1]
asset = next(item for item in json.load(sys.stdin)["assets"] if item["name"] == name)
print(asset["browser_download_url"])
print(asset["digest"])
' "$asset"
  )"
  url="$(sed -n '1p' <<<"$metadata")"
  digest="$(sed -n '2p' <<<"$metadata")"
  [[ "$url" == https://github.com/SagerNet/sing-box/releases/download/* &&
      "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Invalid sing-box release metadata"
  curl -qfsSL --connect-timeout 10 --max-time 120 -o "$directory/$asset" "$url"
  [[ "sha256:$(sha256sum "$directory/$asset" | awk '{print $1}')" == "$digest" ]] ||
    die "sing-box checksum mismatch"
  tar -xzf "$directory/$asset" -C "$directory"
  binary="$directory/${asset%.tar.gz}/sing-box"
  port="$(
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
  )"

  TEST_PORT="$port" python3 - <<'PY' >"$directory/client.json"
import json
import os

values = os.environ
print(json.dumps({
    "log": {"level": "warn"},
    "inbounds": [{
        "type": "socks",
        "tag": "socks-in",
        "listen": "127.0.0.1",
        "listen_port": int(values["TEST_PORT"]),
    }],
    "outbounds": [{
        "type": "vless",
        "tag": "primary",
        "server": values["PRIMARY_IP"],
        "server_port": 443,
        "uuid": values["VPN_UUID"],
        "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True,
            "server_name": values["REALITY_TARGET"],
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {
                "enabled": True,
                "public_key": values["REALITY_PUBLIC_KEY"],
                "short_id": values["REALITY_SHORT_ID"],
            },
        },
    }],
}, indent=2))
PY

  "$binary" check -c "$directory/client.json"
  timeout 20s "$binary" run -c "$directory/client.json" >"$directory/client.log" 2>&1 &
  CLIENT_PID=$!
  egress=""
  for _ in $(seq 1 20); do
    egress="$(
      curl -fsS --max-time 3 --socks5-hostname "127.0.0.1:$port" \
        https://api.ipify.org 2>/dev/null || true
    )"
    [[ -n "$egress" ]] && break
    sleep 0.5
  done
  local client_status=0
  wait "$CLIENT_PID" || client_status=$?
  CLIENT_PID=""
  [[ "$client_status" == 124 ]] || die "The temporary sing-box client exited unexpectedly"
  if [[ "$egress" != "$PRIMARY_IP" ]]; then
    sed -n '1,80p' "$directory/client.log" >&2
    die "Authenticated REALITY client test failed"
  fi
}

generate_client_import() (
  local uri export_directory
  export_directory="$(mktemp -d "$ROOT_DIR/.client-export.XXXXXX")"
  trap 'rm -rf -- "$export_directory"' EXIT
  uri="$(
    python3 - <<'PY'
import os
import urllib.parse

values = os.environ
query = urllib.parse.urlencode({
    "encryption": "none",
    "flow": "xtls-rprx-vision",
    "security": "reality",
    "sni": values["REALITY_TARGET"],
    "fp": "chrome",
    "pbk": values["REALITY_PUBLIC_KEY"],
    "sid": values["REALITY_SHORT_ID"],
    "type": "tcp",
    "headerType": "none",
})
name = urllib.parse.quote("Personal VPN - Vultr Osaka")
print(f'vless://{values["VPN_UUID"]}@{values["PRIMARY_IP"]}:443?{query}#{name}')
PY
  )"
  printf '%s\n' "$uri" >"$export_directory/primary-ios.local.txt"
  chmod 600 "$export_directory/primary-ios.local.txt"
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -o "$export_directory/primary-ios.local.png" -l Q -s 8
    chmod 600 "$export_directory/primary-ios.local.png"
    mv "$export_directory/primary-ios.local.png" "$ROOT_DIR/primary-ios.local.png"
  else
    rm -f "$ROOT_DIR/primary-ios.local.png"
  fi
  mv "$export_directory/primary-ios.local.txt" "$ROOT_DIR/primary-ios.local.txt"
)

[[ "$(uname -s)" == Linux ]] || die "Run this script on Linux or Ubuntu under WSL"
for command in curl python3 ssh ssh-keygen ssh-agent ssh-add openssl awk sed tar sha256sum timeout flock; do
  require "$command"
done

umask 077
if (( VERIFY_ONLY == 1 )); then
  [[ -f "$ENV_FILE" ]] || die "Verification requires an existing $ENV_FILE"
else
  exec {ENV_LOCK_FD}>"$ENV_FILE.lock"
  flock -n "$ENV_LOCK_FD" || die "Another lifecycle operation is using $ENV_FILE"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
export -n VULTR_API_KEY

if [[ -z "${VULTR_API_KEY:-}" ]]; then
  (( VERIFY_ONLY == 0 )) || die "Verification requires a saved VULTR_API_KEY"
  [[ -t 0 ]] || die "Set VULTR_API_KEY in $ENV_FILE"
  read -rsp 'Vultr API key: ' VULTR_API_KEY
  printf '\n'
  set_env VULTR_API_KEY "$VULTR_API_KEY"
fi

if [[ -z "${REALITY_TARGET:-}" ]]; then
  (( VERIFY_ONLY == 0 )) || die "Verification requires a saved REALITY_TARGET"
  [[ -t 0 ]] || die "Set REALITY_TARGET in $ENV_FILE"
  read -rp 'REALITY target hostname: ' REALITY_TARGET
fi
[[ "$REALITY_TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ &&
    "${#REALITY_TARGET}" -le 253 && "$REALITY_TARGET" == *.* ]] ||
  die "REALITY_TARGET must be a hostname without a scheme, path, or whitespace"
if (( VERIFY_ONLY == 0 )); then
  set_env REALITY_TARGET "$REALITY_TARGET"
fi

REGION="${VULTR_REGION:-itm}"
PLAN="${VULTR_PLAN:-vc2-1c-1gb}"
OS_ID="${VULTR_OS_ID:-2284}"
LABEL="${VULTR_INSTANCE_LABEL:-personal-vpn-primary}"
HOSTNAME="${VULTR_HOSTNAME:-vpn-primary}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/travel_ed25519}"
SSH_KEY_NAME="${VULTR_SSH_KEY_NAME:-travel-2026}"
XRAY_VERSION="${XRAY_VERSION:-v26.7.28}"
SKIP_REBOOT="${BRING_UP_SKIP_REBOOT:-0}"
SKIP_CLIENT_TEST="${BRING_UP_SKIP_CLIENT_TEST:-0}"
STORED_INSTANCE_ID="${VULTR_INSTANCE_ID:-}"
export REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY VPN_UUID REALITY_SHORT_ID

[[ "$LABEL" =~ ^personal-vpn-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "Instance label must stay inside the personal-vpn- namespace: $LABEL"
[[ "$XRAY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid XRAY_VERSION"
[[ "$OS_ID" =~ ^[1-9][0-9]*$ ]] || die "Invalid VULTR_OS_ID"
[[ "$REGION" =~ ^[A-Za-z0-9-]+$ && "$PLAN" =~ ^[A-Za-z0-9-]+$ &&
    "$HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
  die "Invalid region, plan, or hostname"
[[ "$SKIP_REBOOT" =~ ^[01]$ && "$SKIP_CLIENT_TEST" =~ ^[01]$ ]] ||
  die "BRING_UP_SKIP_REBOOT and BRING_UP_SKIP_CLIENT_TEST must be 0 or 1"
validate_api_key
CREDENTIAL_COUNT=0
for value in "${REALITY_PRIVATE_KEY:-}" "${REALITY_PUBLIC_KEY:-}" "${VPN_UUID:-}" "${REALITY_SHORT_ID:-}"; do
  if [[ -n "$value" ]]; then
    ((CREDENTIAL_COUNT += 1))
  fi
done
[[ "$CREDENTIAL_COUNT" == 0 || "$CREDENTIAL_COUNT" == 4 ]] ||
  die "Incomplete REALITY credentials; restore the complete set before continuing"
if (( VERIFY_ONLY == 1 || CREDENTIAL_COUNT == 4 )); then
  validate_reality_credentials
fi

RUN_DIR="$(mktemp -d)"
readonly RUN_DIR
ASKPASS="$RUN_DIR/askpass"
AGENT_STARTED=0
CLIENT_PID=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$CLIENT_PID" ]]; then
    wait "$CLIENT_PID" || :
  fi
  if (( AGENT_STARTED == 1 )); then
    if ! ssh-agent -k >/dev/null 2>&1; then
      printf 'WARNING: Could not stop the temporary SSH agent.\n' >&2
    fi
  fi
  rm -rf -- "$RUN_DIR"
  if (( status != 0 )); then
    printf 'ERROR: Setup stopped during %s (exit %s). Check Vultr for billable resources.\n' \
      "${STAGE:-startup}" "$status" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
cat >"$ASKPASS" <<'EOF'
#!/bin/sh
printf '%s\n' "$SSH_KEY_PASSPHRASE"
EOF
chmod 700 "$ASKPASS"

log "Checking Vultr API access"
ACCOUNT_JSON="$(api_get /account)"
ACCOUNT_VALUES="$(vultr_json account <<<"$ACCOUNT_JSON")"
read -r _ REMAINING <<<"$ACCOUNT_VALUES"
log "Remaining Vultr credit: \$$REMAINING"

log "Checking REALITY target"
TLS_OUTPUT="$(
  timeout 20s openssl s_client -connect "$REALITY_TARGET:443" -servername "$REALITY_TARGET" \
    -tls1_3 -alpn h2 </dev/null 2>&1
)"
grep -q 'TLSv1.3' <<<"$TLS_OUTPUT" || die "$REALITY_TARGET does not negotiate TLS 1.3"
grep -q 'ALPN protocol: h2' <<<"$TLS_OUTPUT" || die "$REALITY_TARGET does not negotiate HTTP/2"
grep -q 'Verify return code: 0 (ok)' <<<"$TLS_OUTPUT" || die "$REALITY_TARGET certificate validation failed"
TARGET_HTTP="$(
  curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "https://$REALITY_TARGET/"
)"
[[ "$TARGET_HTTP" == "200" ]] || die "$REALITY_TARGET returned HTTP $TARGET_HTTP instead of 200"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  (( VERIFY_ONLY == 0 )) || die "Verification requires the existing SSH key: $SSH_KEY_PATH"
  log "Generating encrypted SSH key"
  install -d -m 700 "$(dirname "$SSH_KEY_PATH")"
  SSH_KEY_PASSPHRASE="${SSH_KEY_PASSPHRASE:-$(openssl rand -base64 24 | tr -d '\n')}"
  export SSH_KEY_PASSPHRASE
  DISPLAY=:0 SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    ssh-keygen -q -t ed25519 -C "$SSH_KEY_NAME" -f "$SSH_KEY_PATH" </dev/null
  set_env SSH_KEY_PASSPHRASE "$SSH_KEY_PASSPHRASE"
fi
if (( VERIFY_ONLY == 0 )); then
  [[ -f "$SSH_KEY_PATH.pub" ]] || die "Missing public key: $SSH_KEY_PATH.pub"
fi

if [[ -z "${SSH_KEY_PASSPHRASE+x}" ]]; then
  if ssh-keygen -y -P '' -f "$SSH_KEY_PATH" >/dev/null 2>&1; then
    SSH_KEY_PASSPHRASE=""
  else
    (( VERIFY_ONLY == 0 )) || die "Verification requires the saved SSH key passphrase"
    [[ -t 0 ]] || die "Set SSH_KEY_PASSPHRASE in $ENV_FILE"
    read -rsp 'SSH key passphrase: ' SSH_KEY_PASSPHRASE
    printf '\n'
    set_env SSH_KEY_PASSPHRASE "$SSH_KEY_PASSPHRASE"
  fi
fi
export SSH_KEY_PASSPHRASE

AGENT_OUTPUT="$(ssh-agent -a "$RUN_DIR/agent.sock" -s)"
SSH_AGENT_PID="$(sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p' <<<"$AGENT_OUTPUT")"
[[ "$SSH_AGENT_PID" =~ ^[0-9]+$ ]] || die "Could not read the temporary SSH agent PID"
SSH_AUTH_SOCK="$RUN_DIR/agent.sock"
export SSH_AUTH_SOCK SSH_AGENT_PID
AGENT_STARTED=1
DISPLAY=:0 SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
  ssh-add "$SSH_KEY_PATH" </dev/null >/dev/null 2>&1 ||
  die "Could not unlock the SSH key; check SSH_KEY_PASSPHRASE"

if (( VERIFY_ONLY == 0 )); then
  PUBLIC_KEY="$(<"$SSH_KEY_PATH.pub")"
  SSH_KEYS_JSON="$(api_list /ssh-keys ssh_keys)"
  KEY_MATCH_ROWS="$(
    PUBLIC_KEY="$PUBLIC_KEY" python3 -c '
import json, os, sys
matches = [
    item for item in json.load(sys.stdin)["ssh_keys"]
    if item["ssh_key"].strip() == os.environ["PUBLIC_KEY"].strip()
]
print(len(matches))
if len(matches) == 1:
    print(matches[0]["id"])
' <<<"$SSH_KEYS_JSON"
  )"
  mapfile -t KEY_MATCH <<<"$KEY_MATCH_ROWS"

  case "${KEY_MATCH[0]}" in
    0)
      log "Uploading SSH public key"
      KEY_DATA="$(
        PUBLIC_KEY="$PUBLIC_KEY" SSH_KEY_NAME="$SSH_KEY_NAME" python3 -c '
import json, os
print(json.dumps({"name": os.environ["SSH_KEY_NAME"], "ssh_key": os.environ["PUBLIC_KEY"]}))
'
      )"
      KEY_RESPONSE="$(api_post /ssh-keys "$KEY_DATA")"
      VULTR_SSH_KEY_ID="$(
        vultr_json id ssh_key <<<"$KEY_RESPONSE"
      )"
      ;;
    1) VULTR_SSH_KEY_ID="${KEY_MATCH[1]}" ;;
    *) die "The same SSH public key appears more than once in Vultr" ;;
  esac
  set_env VULTR_SSH_KEY_ID "$VULTR_SSH_KEY_ID"
  export VULTR_SSH_KEY_ID
fi

log "Finding Vultr instance"
INSTANCES_JSON="$(api_list /instances instances)"
INSTANCE_MATCH_ROWS="$(
  python3 -c '
import json, sys
label = sys.argv[1]
matches = [item for item in json.load(sys.stdin)["instances"] if item.get("label") == label]
print(len(matches))
if len(matches) == 1:
    item = matches[0]
    print(item["id"])
    print(item["region"])
    print(item["plan"])
    print(item["os_id"])
' "$LABEL" <<<"$INSTANCES_JSON"
)"
mapfile -t INSTANCE_MATCH <<<"$INSTANCE_MATCH_ROWS"

NEW_INSTANCE=0
case "${INSTANCE_MATCH[0]}" in
  0)
    (( VERIFY_ONLY == 0 )) || die "No instance named $LABEL exists"
    log "Creating $LABEL in $REGION"
    INSTANCE_DATA="$(
      python3 - "$REGION" "$PLAN" "$OS_ID" "$LABEL" "$HOSTNAME" "$VULTR_SSH_KEY_ID" <<'PY'
import json
import sys

region, plan, os_id, label, hostname, ssh_key_id = sys.argv[1:]
print(json.dumps({
    "region": region,
    "plan": plan,
    "os_id": int(os_id),
    "label": label,
    "hostname": hostname,
    "sshkey_id": [ssh_key_id],
    "enable_ipv6": False,
    "backups": "disabled",
    "activation_email": False,
}))
PY
    )"
    INSTANCE_RESPONSE="$(api_post /instances "$INSTANCE_DATA")"
    VULTR_INSTANCE_ID="$(
      vultr_json id instance <<<"$INSTANCE_RESPONSE"
    )"
    NEW_INSTANCE=1
    ;;
  1)
    VULTR_INSTANCE_ID="${INSTANCE_MATCH[1]}"
    [[ "${INSTANCE_MATCH[2]}" == "$REGION" ]] || die "Existing instance is in ${INSTANCE_MATCH[2]}, not $REGION"
    [[ "${INSTANCE_MATCH[3]}" == "$PLAN" ]] || die "Existing instance uses ${INSTANCE_MATCH[3]}, not $PLAN"
    [[ "${INSTANCE_MATCH[4]}" == "$OS_ID" ]] || die "Existing instance uses OS ${INSTANCE_MATCH[4]}, not $OS_ID"
    ;;
  *) die "More than one instance is named $LABEL" ;;
esac
if (( VERIFY_ONLY == 1 )) && [[ -n "$STORED_INSTANCE_ID" && "$STORED_INSTANCE_ID" != "$VULTR_INSTANCE_ID" ]]; then
  die "Stored instance ID does not match the configured label"
fi

if (( VERIFY_ONLY == 0 )); then
  set_env VULTR_INSTANCE_ID "$VULTR_INSTANCE_ID"
  set_env VULTR_INSTANCE_LABEL "$LABEL"
  set_env VULTR_REGION "$REGION"
  set_env VULTR_PLAN "$PLAN"
  set_env VULTR_OS_ID "$OS_ID"
fi
export VULTR_INSTANCE_ID

START_REQUESTED=0
for _ in $(seq 1 90); do
  INSTANCE_RESPONSE="$(api_get "/instances/$VULTR_INSTANCE_ID")"
  INSTANCE_STATE="$(vultr_json instance "$VULTR_INSTANCE_ID" <<<"$INSTANCE_RESPONSE")"
  read -r STATUS POWER SERVER_STATUS PRIMARY_IP <<<"$INSTANCE_STATE"
  if (( VERIFY_ONLY == 1 )) && [[ "$STATUS/$POWER/$SERVER_STATUS" != active/running/ok ]]; then
    die "Instance is not ready; verification will not start or modify it"
  fi
  if [[ "$STATUS" == "active" && "$POWER" == "stopped" &&
        "$SERVER_STATUS" == "ok" && "$START_REQUESTED" == "0" &&
        "$NEW_INSTANCE" == "0" && "$VERIFY_ONLY" == "0" ]]; then
    api_post_empty "/instances/$VULTR_INSTANCE_ID/start"
    START_REQUESTED=1
  fi
  if [[ "$STATUS" == "active" && "$POWER" == "running" &&
        "$SERVER_STATUS" == "ok" &&
        "$PRIMARY_IP" =~ ^[0-9]+(\.[0-9]+){3}$ && "$PRIMARY_IP" != "0.0.0.0" ]]; then
    break
  fi
  sleep 5
done
[[ "$STATUS/$POWER/$SERVER_STATUS" == "active/running/ok" ]] ||
  die "Instance did not become ready"
[[ "$PRIMARY_IP" =~ ^[0-9]+(\.[0-9]+){3}$ && "$PRIMARY_IP" != "0.0.0.0" ]] ||
  die "Instance returned an invalid IPv4 address: $PRIMARY_IP"
if (( VERIFY_ONLY == 0 )); then
  set_env PRIMARY_IP "$PRIMARY_IP"
fi
export PRIMARY_IP

if (( NEW_INSTANCE == 1 )); then
  ssh-keygen -R "$PRIMARY_IP" >/dev/null 2>&1 || true
fi

SSH_OPTIONS=(
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -i "$SSH_KEY_PATH"
)
if (( VERIFY_ONLY == 1 )); then
  SSH_OPTIONS+=(-o StrictHostKeyChecking=yes -o UpdateHostKeys=no)
else
  SSH_OPTIONS+=(-o StrictHostKeyChecking=accept-new)
fi

log "Waiting for SSH"
if (( VERIFY_ONLY == 1 )); then
  wait_for_ssh ops
else
  wait_for_ssh root
fi
if (( VERIFY_ONLY == 0 && NEW_INSTANCE == 0 && CREDENTIAL_COUNT == 0 )); then
  EXISTING_PROXY="$(
    ssh "${SSH_OPTIONS[@]}" "root@$PRIMARY_IP" 'python3 -' <<'PY'
import json
from pathlib import Path

config_path = Path("/usr/local/etc/xray/config.json")
contents = config_path.read_text() if config_path.exists() else ""
config = json.loads(contents) if contents.strip() else {}
configured = any(item.get("protocol") == "vless" for item in config.get("inbounds", []))
print("yes" if configured else "no")
PY
  )"
  [[ "$EXISTING_PROXY" == no ]] ||
    die "Existing VLESS configuration found; restore its credentials instead of rotating them implicitly"
fi

if (( VERIFY_ONLY == 0 )); then
  log "Hardening Ubuntu"
  ssh "${SSH_OPTIONS[@]}" "root@$PRIMARY_IP" 'bash -se' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
cloud-init status --wait
apt-get update -qq
apt-get upgrade -y -qq
timedatectl set-timezone UTC
timedatectl set-ntp true

id ops >/dev/null 2>&1 || adduser --disabled-password --gecos "" ops
install -d -m 700 -o ops -g ops /home/ops/.ssh
install -m 600 -o ops -g ops /root/.ssh/authorized_keys /home/ops/.ssh/authorized_keys
usermod -aG sudo ops
printf '%s\n' 'ops ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/ops
chmod 440 /etc/sudoers.d/ops
visudo -cf /etc/sudoers.d/ops >/dev/null
REMOTE

  wait_for_ssh ops
  [[ "$(ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'sudo whoami')" == root ]] ||
    die "ops sudo verification failed; SSH policy has not been changed"

  ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
cat >/etc/ssh/sshd_config.d/00-personal-vpn.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
chmod 644 /etc/ssh/sshd_config.d/00-personal-vpn.conf
sshd -t
systemctl restart ssh

apt-get install -y -qq nftables
command -v ufw >/dev/null 2>&1 && ufw --force disable >/dev/null
cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif lo accept

    tcp dport 22 accept
    tcp dport { 80, 443 } accept
    udp dport 443 accept

    ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
    ip6 nexthdr icmpv6 accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF
nft -c -f /etc/nftables.conf
systemctl enable --now nftables >/dev/null
nft -f /etc/nftables.conf

cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system >/dev/null
REMOTE

  wait_for_ssh ops
  [[ "$(ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'sudo whoami')" == "root" ]] ||
    die "ops sudo verification failed"

  log "Checking target from the server"
  ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'bash -se' -- "$REALITY_TARGET" <<'REMOTE'
set -euo pipefail
target="$1"
output="$(timeout 20s openssl s_client -connect "$target:443" -servername "$target" -tls1_3 -alpn h2 </dev/null 2>&1)"
grep -q 'TLSv1.3' <<<"$output" || {
  echo "FAIL: target does not negotiate TLS 1.3" >&2
  exit 1
}
grep -q 'ALPN protocol: h2' <<<"$output" || {
  echo "FAIL: target does not negotiate HTTP/2" >&2
  exit 1
}
grep -q 'Verify return code: 0 (ok)' <<<"$output" || {
  echo "FAIL: target certificate validation failed" >&2
  exit 1
}
[[ "$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "https://$target/")" == "200" ]] || {
  echo "FAIL: target does not return HTTP 200" >&2
  exit 1
}
REMOTE

  log "Installing Xray $XRAY_VERSION"
  ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'sudo bash -se' -- \
    "$XRAY_VERSION" "$XRAY_INSTALLER_COMMIT" "$XRAY_INSTALLER_SHA256" <<'REMOTE'
set -euo pipefail
version="$1"
installer_commit="$2"
installer_sha256="$3"
installed=""
if command -v xray >/dev/null 2>&1; then
  installed="$(xray version | awk 'NR==1{print $2}')"
fi
if [[ "v$installed" != "$version" ]]; then
  workdir="$(mktemp -d)"
  trap 'rm -rf -- "$workdir"' EXIT
  curl -qfsSL --connect-timeout 10 --max-time 120 \
    "https://raw.githubusercontent.com/XTLS/Xray-install/$installer_commit/install-release.sh" \
    -o "$workdir/install-release.sh"
  actual_sha256="$(sha256sum "$workdir/install-release.sh" | awk '{print $1}')"
  [[ "$actual_sha256" == "$installer_sha256" ]] || {
    echo "FAIL: Xray installer checksum mismatch" >&2
    exit 1
  }
  if ! TERM=xterm bash "$workdir/install-release.sh" install --version "$version" >"$workdir/install.log" 2>&1; then
    cat "$workdir/install.log" >&2
    exit 1
  fi
fi
[[ "v$(xray version | awk 'NR==1{print $2}')" == "$version" ]]
REMOTE

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ||
        -z "${VPN_UUID:-}" || -z "${REALITY_SHORT_ID:-}" ]]; then
    log "Generating REALITY credentials"
    CREDENTIALS="$(
      ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'bash -se' <<'REMOTE'
set -euo pipefail
keys="$(xray x25519)"
private="$(awk '/^PrivateKey:/{print $2}' <<<"$keys")"
public="$(awk '/^Password/{print $3}' <<<"$keys")"
uuid="$(xray uuid)"
short_id="$(openssl rand -hex 8)"
printf '%s\n%s\n%s\n%s\n' "$private" "$public" "$uuid" "$short_id"
REMOTE
    )"
    mapfile -t VALUES <<<"$CREDENTIALS"
    ((${#VALUES[@]} == 4)) || die "Unexpected credential output"
    REALITY_PRIVATE_KEY="${VALUES[0]}"
    REALITY_PUBLIC_KEY="${VALUES[1]}"
    VPN_UUID="${VALUES[2]}"
    REALITY_SHORT_ID="${VALUES[3]}"
    validate_reality_credentials
    set_env REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
    set_env REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
    set_env VPN_UUID "$VPN_UUID"
    set_env REALITY_SHORT_ID "$REALITY_SHORT_ID"
    export REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY VPN_UUID REALITY_SHORT_ID
  fi

  validate_reality_credentials
  log "Writing Xray configuration"
  CONFIG="$(
    python3 - <<'PY'
import json
import os

values = os.environ
print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": values["VPN_UUID"], "flow": "xtls-rprx-vision"}],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "target": values["REALITY_TARGET"] + ":443",
                    "serverNames": [values["REALITY_TARGET"]],
                    "privateKey": values["REALITY_PRIVATE_KEY"],
                    "shortIds": [values["REALITY_SHORT_ID"]],
                    "minClientVer": "1.8.1",
                },
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True,
            },
        },
        {
            "tag": "camouflage-80",
            "listen": "0.0.0.0",
            "port": 80,
            "protocol": "dokodemo-door",
            "settings": {
                "address": values["REALITY_TARGET"],
                "port": 80,
                "network": "tcp",
            },
        },
    ],
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "outboundTag": "block",
                "inboundTag": ["reality-in"],
                "ip": ["geoip:cn", "geoip:private"],
            },
            {"outboundTag": "block", "protocol": ["bittorrent"]},
        ],
    },
}, indent=2))
PY
  )"
  printf '%s\n' "$CONFIG" |
    ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" \
      'sudo install -m 600 /dev/stdin /usr/local/etc/xray/config.json.pending'
  ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'sudo bash -se' <<'REMOTE'
set -euo pipefail
test_log="$(mktemp)"
trap 'rm -f /usr/local/etc/xray/config.json.pending "$test_log"' EXIT
service_user="$(systemctl show xray -p User --value)"
service_user="${service_user:-root}"
service_group="$(systemctl show xray -p Group --value)"
service_group="${service_group:-$(id -gn "$service_user")}"
chown "root:$service_group" /usr/local/etc/xray/config.json.pending
chmod 640 /usr/local/etc/xray/config.json.pending
if ! sudo -u "$service_user" -g "$service_group" xray run -test -c /usr/local/etc/xray/config.json.pending >"$test_log" 2>&1; then
  cat "$test_log" >&2
  exit 1
fi
grep -q 'Configuration OK.' "$test_log" || {
  cat "$test_log" >&2
  exit 1
}
mv /usr/local/etc/xray/config.json.pending /usr/local/etc/xray/config.json
systemctl enable --now xray >/dev/null
systemctl restart xray
REMOTE

  if [[ "$SKIP_REBOOT" != "1" ]]; then
    log "Rebooting and checking persistence"
    BOOT_ID_BEFORE="$(
      ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'cat /proc/sys/kernel/random/boot_id'
    )"
    ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" \
      'sudo systemd-run --on-active=1s --collect /usr/bin/systemctl reboot' \
      >/dev/null
    BOOT_ID_AFTER=""
    for _ in $(seq 1 120); do
      BOOT_ID_AFTER="$(
        ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" \
          'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true
      )"
      if [[ -n "$BOOT_ID_AFTER" && "$BOOT_ID_AFTER" != "$BOOT_ID_BEFORE" ]]; then
        break
      fi
      sleep 5
    done
    [[ -n "$BOOT_ID_AFTER" && "$BOOT_ID_AFTER" != "$BOOT_ID_BEFORE" ]] ||
      die "Server reboot did not complete"
  fi
else
  validate_reality_credentials
fi

log "Verifying server"
ssh "${SSH_OPTIONS[@]}" "ops@$PRIMARY_IP" 'bash -se' <<'REMOTE'
set -euo pipefail
for _ in $(seq 1 30); do
  [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]] && break
  sleep 2
done
[[ "$(sudo systemctl is-active xray)" == "active" ]] || {
  echo "FAIL: xray is not active" >&2
  exit 1
}
[[ "$(sudo systemctl is-active nftables)" == "active" ]] || {
  echo "FAIL: nftables is not active" >&2
  exit 1
}
[[ "$(sudo nft list ruleset | grep -c 'policy drop')" == "2" ]] || {
  echo "FAIL: nftables drop policies are missing" >&2
  exit 1
}
[[ "$(ip -6 addr show scope global | grep -c inet6 || true)" == "0" ]] || {
  echo "FAIL: global IPv6 is still enabled" >&2
  exit 1
}
sudo ss -tlnH 'sport = :443' | grep -q . || {
  echo "FAIL: nothing is listening on TCP 443" >&2
  exit 1
}
sudo ss -tlnH 'sport = :80' | grep -q . || {
  echo "FAIL: nothing is listening on TCP 80" >&2
  exit 1
}
[[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]] || {
  echo "FAIL: clock is not synchronized" >&2
  exit 1
}
REMOTE

HTTPS_CODE="$(
  curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    "https://$REALITY_TARGET/" --resolve "$REALITY_TARGET:443:$PRIMARY_IP"
)"
[[ "$HTTPS_CODE" == "200" ]] || die "Camouflage HTTPS returned $HTTPS_CODE"
CERTIFICATE_OUTPUT="$(
  timeout 20s openssl s_client -connect "$PRIMARY_IP:443" -servername "$REALITY_TARGET" </dev/null 2>&1
)"
grep -q 'Verify return code: 0 (ok)' <<<"$CERTIFICATE_OUTPUT" ||
  die "Camouflage certificate validation failed"

if [[ "$SKIP_CLIENT_TEST" != "1" ]]; then
  log "Testing authenticated REALITY traffic"
  test_reality_client
fi

if (( VERIFY_ONLY == 0 || EXPORT_CLIENT == 1 )); then
  generate_client_import
fi
log "READY label=$LABEL ip=$PRIMARY_IP"
if (( VERIFY_ONLY == 0 || EXPORT_CLIENT == 1 )); then
  log "Client import: $ROOT_DIR/primary-ios.local.txt"
  if [[ -f "$ROOT_DIR/primary-ios.local.png" ]]; then
    log "QR code: $ROOT_DIR/primary-ios.local.png"
  fi
fi
