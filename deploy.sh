#!/usr/bin/env bash
# Wizard for the InfluxDB → MySQL bridge. Per spec §6.
# POSIX bash, set -euo pipefail. shellcheck-clean.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

# Regex mirrors of app/config.py (M5 verifies these stay in sync).
RE_PREFIX='^[a-z][a-z0-9_]{0,30}$'
RE_FLUX_STR='^[A-Za-z0-9_./-]{1,128}$'
RE_URL='^https?://[A-Za-z0-9.-]+(:[0-9]+)?$'

declare -A VALS
STATE="fresh"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

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

# prompt_value VAR LABEL REGEX [secret]
# Single-value prompt. Detects common mistakes (commas, spaces) and explains them.
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
    if [[ -n "$regex" && ! "$val" =~ $regex ]]; then
      if [[ "$val" == *,* ]]; then
        yellow "  invalid: this field accepts ONE value only — no commas." >&2
      elif [[ "$val" == *' '* ]]; then
        yellow "  invalid: no spaces allowed." >&2
      else
        yellow "  invalid format (allowed: letters, digits, _, -, ., /)." >&2
      fi
      continue
    fi
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

# Multi-prompt for INFLUX_FIELDS — collects an allowlist of field names.
# UX: prints a header, numbers each prompt, shows the running list, gives
# specific errors for common mistakes (commas, spaces, duplicates).
prompt_fields() {
  local current="${VALS[INFLUX_FIELDS]:-}"
  if [[ -n "$current" ]]; then
    echo "" >&2
    echo "Current INFLUX_FIELDS: $current" >&2
    printf 'Press Enter to keep, or type "edit" to redo: ' >&2
    local choice=""; read -r choice
    [[ "$choice" != "edit" ]] && return 0
  fi

  echo "" >&2
  green "INFLUX_FIELDS — the list of Influx _field names this bridge will ingest."
  dim   "Enter ONE field name per line. Press Enter on a blank line when done."
  dim   "Example fields: wheat_level, white_corn_level, yellow_corn_level"
  echo "" >&2

  local values=() v="" dup="" idx=1 collected=""
  while true; do
    if (( ${#values[@]} > 0 )); then
      local IFS_TMP="$IFS"; IFS=', '; collected="${values[*]}"; IFS="$IFS_TMP"
      printf '  Field #%d  [collected: %s]: ' "$idx" "$collected" >&2
    else
      printf '  Field #%d: ' "$idx" >&2
    fi
    read -r v
    if [[ -z "$v" ]]; then
      if (( ${#values[@]} == 0 )); then
        yellow "  at least one field is required" >&2
        continue
      fi
      break
    fi
    if [[ "$v" == *,* ]]; then
      yellow "  enter ONE field at a time — no commas. (You'll be prompted again for the next.)" >&2
      continue
    fi
    if [[ "$v" == *' '* ]]; then
      yellow "  no spaces allowed in field names." >&2
      continue
    fi
    if [[ ! "$v" =~ $RE_FLUX_STR ]]; then
      yellow "  invalid format (allowed: letters, digits, _, -, ., / — max 128 chars)." >&2
      continue
    fi
    dup=""
    for existing in "${values[@]}"; do [[ "$existing" == "$v" ]] && dup="yes" && break; done
    if [[ -n "$dup" ]]; then
      yellow "  '$v' already added — pick another" >&2
      continue
    fi
    values+=("$v")
    idx=$((idx + 1))
    if (( ${#values[@]} >= 64 )); then
      yellow "  reached max of 64 fields" >&2
      break
    fi
  done

  local IFS_BAK="$IFS"; IFS=','; VALS[INFLUX_FIELDS]="${values[*]}"; IFS="$IFS_BAK"
  green "  → ${#values[@]} field(s): ${VALS[INFLUX_FIELDS]}"
  echo "" >&2
}

run_prompts() {
  echo ""
  green "── silo-data bridge configuration ─────────────────────────────────"
  dim   "One bridge ingests ONE measurement and a list of fields from one"
  dim   "Influx bucket into one MySQL table. Most prompts are single-value;"
  dim   "INFLUX_FIELDS is a multi-prompt loop."
  echo ""

  prompt_value TABLE_PREFIX        "TABLE_PREFIX (e.g. silo_farm_a)"        "$RE_PREFIX"
  prompt_value INFLUX_URL          "INFLUX_URL (e.g. http://10.0.0.5:8086)" "$RE_URL"
  prompt_value INFLUX_TOKEN        "INFLUX_TOKEN"                           ""              secret
  prompt_value INFLUX_ORG          "INFLUX_ORG (e.g. easyfoods)"            "$RE_FLUX_STR"
  prompt_value INFLUX_BUCKET       "INFLUX_BUCKET (e.g. plc)"               "$RE_FLUX_STR"
  prompt_value INFLUX_MEASUREMENT  "INFLUX_MEASUREMENT (single name, e.g. Silo)" "$RE_FLUX_STR"
  prompt_fields
  prompt_value MYSQL_HOST          "MYSQL_HOST"                             ""
  prompt_int   MYSQL_PORT          "MYSQL_PORT"                             1 65535 3306
  prompt_value MYSQL_USER          "MYSQL_USER"                             ""
  prompt_value MYSQL_PASSWORD      "MYSQL_PASSWORD"                         ""              secret
  prompt_value MYSQL_DB            "MYSQL_DB"                               ""
  prompt_int   POLL_INTERVAL_SECONDS "POLL_INTERVAL_SECONDS"                5 3600 10
  prompt_int   QUERY_WINDOW_SECONDS  "QUERY_WINDOW_SECONDS"                 1 86400 20

  local poll="${VALS[POLL_INTERVAL_SECONDS]}" win="${VALS[QUERY_WINDOW_SECONDS]}"
  if (( win < 2 * poll )); then
    die_with_code 2 "QUERY_WINDOW_SECONDS must be >= 2 * POLL_INTERVAL_SECONDS"
  fi
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    local backup="${ENV_FILE}.bak.$(date +%s)"
    cp "$ENV_FILE" "$backup"; chmod 600 "$backup"
    green "Backed up existing .env to $(basename "$backup")"
  fi
  {
    for k in TABLE_PREFIX INFLUX_URL INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET \
             INFLUX_MEASUREMENT INFLUX_FIELDS \
             MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DB \
             POLL_INTERVAL_SECONDS QUERY_WINDOW_SECONDS; do
      printf '%s=%s\n' "$k" "${VALS[$k]}"
    done
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
