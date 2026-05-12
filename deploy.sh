#!/usr/bin/env bash
# Wizard for the InfluxDB → MySQL bridge. Per spec §6.
# POSIX bash, set -euo pipefail. shellcheck-clean.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# Regex mirrors of app/config.py (M5 verifies these stay in sync).
RE_PREFIX='^[a-z][a-z0-9_]{0,30}$'
RE_FLUX_STR='^[A-Za-z0-9_./-]{1,128}$'
RE_TAG_VALUE='^[A-Za-z0-9_./-]{1,64}$'
RE_URL='^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'

declare -A VALS
STATE="fresh"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die_with_code() { local c="$1"; shift; red "$*" >&2; exit "$c"; }

check_deps() {
  if ! command -v docker >/dev/null 2>&1; then
    red "docker not found." >&2
    echo "Install: https://docs.docker.com/engine/install/ubuntu/" >&2
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    red "docker compose plugin not found." >&2
    echo "Install: https://docs.docker.com/compose/install/" >&2
    exit 1
  fi
}

mask() {
  local s="$1"; local n=${#s}
  if (( n <= 4 )); then echo "xxxx"; else printf 'xxxx…%s' "${s: -4}"; fi
}

load_existing() {
  [[ -f "$ENV_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] && VALS[$key]="$value"
  done < "$ENV_FILE"
}

prompt_value() {
  local var="$1" label="$2" regex="$3" secret="${4:-}"
  local current="${VALS[$var]:-}" hint="" val=""
  if [[ -n "$current" ]]; then
    if [[ "$secret" == "secret" ]]; then hint=" [$(mask "$current")]"; else hint=" [$current]"; fi
  fi
  while true; do
    if [[ "$secret" == "secret" ]]; then
      printf '%s%s: ' "$label" "$hint" >&2
      read -rs val; printf '\n' >&2
    else
      printf '%s%s: ' "$label" "$hint" >&2
      read -r val
    fi
    [[ -z "$val" && -n "$current" ]] && val="$current"
    if [[ -z "$val" ]]; then yellow "  (required)" >&2; continue; fi
    if [[ -n "$regex" && ! "$val" =~ $regex ]]; then yellow "  invalid format" >&2; continue; fi
    VALS[$var]="$val"; return 0
  done
}

prompt_int() {
  local var="$1" label="$2" lo="$3" hi="$4" default="$5"
  local current="${VALS[$var]:-$default}" val=""
  while true; do
    printf '%s [%s]: ' "$label" "$current" >&2
    read -r val; [[ -z "$val" ]] && val="$current"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then yellow "  not a number" >&2; continue; fi
    if (( val < lo || val > hi )); then yellow "  out of range [$lo,$hi]" >&2; continue; fi
    VALS[$var]="$val"; return 0
  done
}

prompt_tag_values() {
  local current="${VALS[INFLUX_TAG_VALUES]:-}"
  if [[ -n "$current" ]]; then
    echo "Current INFLUX_TAG_VALUES: $current" >&2
    printf 'Press Enter to keep, or type "edit" to redo: ' >&2
    local choice=""; read -r choice
    [[ "$choice" != "edit" ]] && return 0
  fi
  local values=() v="" dup=""
  while true; do
    printf 'Add tag value (Enter to finish): ' >&2
    read -r v
    if [[ -z "$v" ]]; then
      if (( ${#values[@]} == 0 )); then yellow "  at least one tag value is required" >&2; continue; fi
      break
    fi
    if [[ ! "$v" =~ $RE_TAG_VALUE ]]; then yellow "  invalid format" >&2; continue; fi
    dup=""
    for existing in "${values[@]}"; do [[ "$existing" == "$v" ]] && dup="yes" && break; done
    [[ -z "$dup" ]] && values+=("$v")
    if (( ${#values[@]} >= 64 )); then yellow "  reached max of 64 tag values" >&2; break; fi
  done
  local IFS_BAK="$IFS"; IFS=','; VALS[INFLUX_TAG_VALUES]="${values[*]}"; IFS="$IFS_BAK"
}

prompt_optional_secret() {
  local var="$1" label="$2"
  local current="${VALS[$var]:-}" hint="" val=""
  if [[ -n "$current" ]]; then
    hint=" [$(mask "$current")]"
  fi
  printf '%s%s (Enter to skip): ' "$label" "$hint" >&2
  read -rs val; printf '\n' >&2
  if [[ -z "$val" && -n "$current" ]]; then val="$current"; fi
  VALS[$var]="${val:-}"
}

run_prompts() {
  prompt_value TABLE_PREFIX        "TABLE_PREFIX (e.g. silo_farm_a)"  "$RE_PREFIX"
  prompt_value INFLUX_URL          "INFLUX_URL (https://host:8086)"   "$RE_URL"
  prompt_value INFLUX_TOKEN        "INFLUX_TOKEN"                     ""             secret
  prompt_value INFLUX_ORG          "INFLUX_ORG"                       "$RE_FLUX_STR"
  prompt_value INFLUX_BUCKET       "INFLUX_BUCKET"                    "$RE_FLUX_STR"
  prompt_value INFLUX_MEASUREMENT  "INFLUX_MEASUREMENT"               "$RE_FLUX_STR"
  prompt_value INFLUX_FIELD        "INFLUX_FIELD"                     "$RE_FLUX_STR"
  prompt_value INFLUX_TAG_KEY      "INFLUX_TAG_KEY (e.g. silo)"       "$RE_PREFIX"
  prompt_tag_values
  prompt_value MYSQL_HOST          "MYSQL_HOST"                       ""
  prompt_int   MYSQL_PORT          "MYSQL_PORT"                       1 65535 3306
  prompt_value MYSQL_USER          "MYSQL_USER"                       ""
  prompt_value MYSQL_PASSWORD      "MYSQL_PASSWORD"                   ""             secret
  prompt_value MYSQL_DB            "MYSQL_DB"                         ""
  prompt_int   POLL_INTERVAL_SECONDS "POLL_INTERVAL_SECONDS"          5 3600 10
  prompt_int   QUERY_WINDOW_SECONDS  "QUERY_WINDOW_SECONDS"           1 86400 20
  local poll="${VALS[POLL_INTERVAL_SECONDS]}" win="${VALS[QUERY_WINDOW_SECONDS]}"
  if (( win < 2 * poll )); then
    die_with_code 2 "QUERY_WINDOW_SECONDS must be >= 2 * POLL_INTERVAL_SECONDS"
  fi
  prompt_optional_secret GOOGLE_SCRIPT_TARGET_TOKEN "GOOGLE_SCRIPT_TARGET_TOKEN (optional)"
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    local backup="${ENV_FILE}.bak.$(date +%s)"
    cp "$ENV_FILE" "$backup"; chmod 600 "$backup"
    green "Backed up existing .env to $(basename "$backup")"
  fi
  {
    for k in TABLE_PREFIX INFLUX_URL INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET \
             INFLUX_MEASUREMENT INFLUX_FIELD INFLUX_TAG_KEY INFLUX_TAG_VALUES \
             MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB \
             POLL_INTERVAL_SECONDS QUERY_WINDOW_SECONDS; do
      printf '%s=%s\n' "$k" "${VALS[$k]}"
    done
    printf 'GOOGLE_SCRIPT_TARGET_TOKEN=%s\n' "${VALS[GOOGLE_SCRIPT_TARGET_TOKEN]:-}"
    printf 'COMPOSE_PROJECT_NAME=%s\n' "${VALS[TABLE_PREFIX]}"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  green "Wrote $ENV_FILE (mode 600)"
}

preflight() {
  local url="${VALS[INFLUX_URL]}" token="${VALS[INFLUX_TOKEN]}"
  local mh="${VALS[MYSQL_HOST]}" mp="${VALS[MYSQL_PORT]}"
  local mu="${VALS[MYSQL_USER]}" mw="${VALS[MYSQL_PASSWORD]}" mdb="${VALS[MYSQL_DB]}"

  yellow "Pre-flight: probing Influx ${url}/health …"
  if ! curl -fsS --max-time 5 -H "Authorization: Token ${token}" "${url}/health" >/dev/null 2>&1; then
    if ! curl -fsS --max-time 5 "${url}/health" >/dev/null 2>&1; then
      die_with_code 3 "Influx /health probe FAILED. Check INFLUX_URL and connectivity."
    fi
  fi
  green "  Influx /health: OK"

  yellow "Pre-flight: probing MySQL ${mh}:${mp} …"
  if ! docker run --rm --network host \
        -e MYSQL_PWD="${mw}" mysql:8.4 \
        mysql -h "${mh}" -P "${mp}" -u "${mu}" -e "SELECT 1" "${mdb}" \
        >/dev/null 2>&1; then
    die_with_code 3 "MySQL SELECT 1 probe FAILED. Check MYSQL_* values and connectivity."
  fi
  green "  MySQL SELECT 1: OK"
}

state_menu() {
  [[ -f "$ENV_FILE" ]] || return 0
  echo "Existing .env detected."
  echo "  (1) Reuse existing"
  echo "  (2) Update"
  echo "  (3) Cancel"
  while true; do
    printf 'Choice [1/2/3]: '
    local c=""; read -r c
    case "$c" in
      1) STATE="reuse"; return 0 ;;
      2) STATE="update"; return 0 ;;
      3) exit 0 ;;
      *) yellow "  pick 1, 2, or 3" ;;
    esac
  done
}

main() {
  check_deps
  load_existing
  state_menu
  case "$STATE" in
    reuse) green "Reusing existing .env" ;;
    *)     run_prompts; write_env ;;
  esac
  preflight

  yellow "Building image …"
  docker compose build

  yellow "Dry-run (Influx query, no writes) …"
  docker compose run --rm bridge --dry-run

  printf 'Proceed with deployment? (y/N): '
  local proceed=""; read -r proceed
  if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
    yellow "Aborted by user. Bridge not started."; exit 0
  fi

  yellow "Starting bridge …"
  docker compose up -d --build
  docker compose ps
  echo
  yellow "Last 20 log lines:"
  docker compose logs --tail 20 bridge || true

  local container="${VALS[TABLE_PREFIX]}_influx_mysql_bridge"
  yellow "Waiting for healthy status (up to 60s) …"
  local i=0 status=""
  while (( i < 12 )); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo missing)"
    if [[ "$status" == "healthy" ]]; then green "Health: $status"; return 0; fi
    sleep 5; i=$((i+1))
  done
  yellow "Health did not reach 'healthy' within 60s. Run: docker compose logs bridge"
}

main "$@"
