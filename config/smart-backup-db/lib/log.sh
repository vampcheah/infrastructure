#!/usr/bin/env bash
# Logging helpers. Caller must have LOG_FILE set before calling log_init.

log_init() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
}

log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  # tee -a writes the line to both the log file and stderr so cron's
  # redirection (cron.txt) still captures it for emergency debugging.
  printf '%s [%s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE" >&2
}

log_info()  { log "INFO"  "$@"; }
log_ok()    { log "OK"    "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
