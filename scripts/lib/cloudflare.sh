#!/usr/bin/env bash

CLOUDFLARE_JSON_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cloudflare_json.py"
CLOUDFLARE_API="${CLOUDFLARE_API:-https://api.cloudflare.com/client/v4}"

cloudflare_json() {
  python3 "$CLOUDFLARE_JSON_HELPER" "$@"
}

cloudflare_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

validate_cloudflare_token() {
  [[ "${CLOUDFLARE_API_TOKEN:-}" =~ ^[A-Za-z0-9._-]{20,}$ ]] ||
    cloudflare_error "CLOUDFLARE_API_TOKEN is missing or contains invalid characters"
}

# Cloudflare reports failures inside the response envelope, so callers validate
# the body rather than the status code. That keeps the API's own error text.
cf_request() (
  local method="$1" path="$2"
  local body_file
  body_file="$(mktemp)" || return 1
  trap 'rm -f -- "$body_file"' EXIT
  local -a options=(
    -q --silent --show-error --connect-timeout 10 --max-time 30
    -X "$method" -H 'Content-Type: application/json'
  )
  if [[ "$method" == GET ]]; then
    options+=(--retry 2 --retry-delay 1 --retry-max-time 65)
  fi
  if (($# == 3)); then
    options+=(--data-binary @-)
  fi
  if ! curl "${options[@]}" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
    -o "$body_file" "${CLOUDFLARE_API%/}$path" <<<"${3:-}"; then
    cloudflare_error "Cloudflare $method ${path%%\?*} failed before a complete response"
    return 1
  fi
  cat "$body_file"
)

# The proxy hostname may sit below the zone, so try each parent domain in turn.
cf_zone_id() {
  local host="$1" suffix zone
  if [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi
  while read -r suffix; do
    zone="$(cf_request GET "/zones?name=$suffix&status=active" |
      cloudflare_json zone-id "$suffix")" || return 1
    if [[ -n "$zone" ]]; then
      printf '%s\n' "$zone"
      return 0
    fi
  done < <(cloudflare_json zone-suffixes "$host")
  cloudflare_error "No active Cloudflare zone covers $host; add the domain to Cloudflare first"
}

cf_dns_apply() {
  local zone="$1" host="$2" address="$3" record payload response
  record="$(cf_request GET "/zones/$zone/dns_records?type=A&name=$host" |
    cloudflare_json record-id "$host")" || return 1
  payload="$(
    python3 - "$host" "$address" <<'PY'
import json
import sys

host, address = sys.argv[1:]
print(json.dumps({
    "type": "A",
    "name": host,
    "content": address,
    "proxied": True,
    "ttl": 1,
    "comment": "china-travel-vpn origin",
}))
PY
  )"
  if [[ -n "$record" ]]; then
    response="$(cf_request PUT "/zones/$zone/dns_records/$record" "$payload")" || return 1
  else
    response="$(cf_request POST "/zones/$zone/dns_records" "$payload")" || return 1
  fi
  cloudflare_json record-applied "$host" "$address" <<<"$response"
}

cf_dns_remove() {
  local zone="$1" host="$2" record
  record="$(cf_request GET "/zones/$zone/dns_records?type=A&name=$host" |
    cloudflare_json record-id "$host")" || return 1
  [[ -n "$record" ]] || return 0
  cf_request DELETE "/zones/$zone/dns_records/$record" |
    python3 "$CLOUDFLARE_JSON_HELPER" record-id "$host" >/dev/null 2>&1 || true
  printf '%s\n' "$record"
}

# Cloudflare signs the CSR; the private key stays on the origin server.
cf_origin_certificate() {
  local host="$1" csr="$2" payload
  payload="$(
    python3 - "$host" "$csr" <<'PY'
import json
import sys

host, csr = sys.argv[1:]
print(json.dumps({
    "hostnames": [host],
    "request_type": "origin-ecc",
    "requested_validity": 5475,
    "csr": csr,
}))
PY
  )"
  cf_request POST "/certificates" "$payload" | cloudflare_json certificate
}

cf_certificate_revoke() {
  local identifier="$1"
  cf_request DELETE "/certificates/$identifier" >/dev/null 2>&1 || true
}
