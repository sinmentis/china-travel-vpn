#!/usr/bin/env bash

VULTR_JSON_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vultr_json.py"

vultr_json() {
  python3 "$VULTR_JSON_HELPER" "$@"
}

vultr_error() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

validate_api_key() {
  [[ "${VULTR_API_KEY:-}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    vultr_error "VULTR_API_KEY is missing or contains invalid characters"
}

api_request() (
  local method="$1" path="$2" accepted="$3"
  local code body_file
  # curl rewinds regular files on retry; stdout would concatenate response bodies.
  body_file="$(mktemp)" || return 1
  trap 'rm -f -- "$body_file"' EXIT
  local -a options=(
    -q --silent --show-error --connect-timeout 10 --max-time 30
    -X "$method"
  )
  if [[ "$method" == GET ]]; then
    options+=(--retry 2 --retry-delay 1 --retry-max-time 65)
  fi
  if (($# == 4)); then
    options+=(-H 'Content-Type: application/json' --data-binary @-)
  fi
  if ! code="$(curl "${options[@]}" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_API_KEY") \
    -o "$body_file" -w '%{http_code}' "${API%/}$path" <<<"${4:-}")"; then
    vultr_error "Vultr $method ${path%%\?*} failed before a complete response"
    return 1
  fi
  if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
    vultr_error "Vultr $method ${path%%\?*} returned an invalid transport response"
    return 1
  fi
  if [[ ",$accepted," != *",$code,"* ]]; then
    vultr_error "Vultr $method ${path%%\?*} returned HTTP $code; check API access and resource state"
    return 1
  fi
  cat "$body_file"
)

api_get() {
  api_request GET "$1" 200
}

api_post() {
  api_request POST "$1" 201 "$2"
}

api_post_empty() {
  api_request POST "$1" 204 >/dev/null
}

api_list() {
  local endpoint="$1" key="$2" cursor="" page next previous
  local -a pages=() cursors=()
  for _ in $(seq 1 100); do
    page="$(api_get "$endpoint?per_page=500${cursor:+&cursor=$cursor}")" || return 1
    page="$(vultr_json collection "$key" <<<"$page")" || return 1
    pages+=("$page")
    next="$(vultr_json cursor "$key" <<<"$page")" || return 1
    if [[ -z "$next" ]]; then
      printf '%s\n' "${pages[@]}" | vultr_json merge "$key"
      return
    fi
    for previous in "${cursors[@]}"; do
      [[ "$previous" != "$next" ]] || {
        vultr_error "Vultr returned a repeated pagination cursor"
        return 1
      }
    done
    cursors+=("$next")
    cursor="$next"
  done
  vultr_error "Vultr pagination exceeded 100 pages; refusing incomplete results"
}

delete_instance() {
  local identifier="$1" listing present
  vultr_json validate-id "$identifier" >/dev/null || return 1
  api_request DELETE "/instances/$identifier" 204,404 >/dev/null || return 1
  for _ in $(seq 1 60); do
    listing="$(api_list /instances instances)" || return 1
    present="$(vultr_json has-instance "$identifier" <<<"$listing")" || return 1
    [[ "$present" != yes ]] && return 0
    sleep 5
  done
  vultr_error "Instance $identifier is still present after the deletion deadline"
}
