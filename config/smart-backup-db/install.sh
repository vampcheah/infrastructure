#!/usr/bin/env bash
# Dependency check + crontab installer for smart-backup-db.
# Run this after editing config.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

die() { echo "FATAL: $*" >&2; exit 1; }

check_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "  MISSING: $cmd   — install: $hint"
    return 1
  fi
  echo "  OK:      $cmd"
  return 0
}

[ -f "$CONFIG_FILE" ] || die "config missing: $CONFIG_FILE"
# shellcheck source=config.sh
source "$CONFIG_FILE"

missing=0

echo "[core dependencies]"
check_cmd bash  "already required"          || missing=1
check_cmd gzip  "apt install -y gzip"       || missing=1
check_cmd split "apt install -y coreutils"  || missing=1
check_cmd find  "apt install -y findutils"  || missing=1

need_mysql=0; need_pg=0
for t in "${TARGETS[@]}"; do
  IFS='|' read -r type _rest <<<"$t"
  case "$type" in
    mysql)    need_mysql=1 ;;
    postgres) need_pg=1 ;;
  esac
done

echo
echo "[per-target dependencies]"
if [ "$need_mysql" -eq 1 ]; then
  check_cmd mysqldump "apt install -y mysql-client" || missing=1
  check_cmd mysql     "apt install -y mysql-client" || missing=1
fi
if [ "$need_pg" -eq 1 ]; then
  check_cmd pg_dump    "apt install -y postgresql-client" || missing=1
  check_cmd psql       "apt install -y postgresql-client" || missing=1
  check_cmd pg_restore "apt install -y postgresql-client" || missing=1
fi
if [ "$DESTINATION" = "s3" ]; then
  check_cmd aws "apt install -y awscli  (or: pip install awscli)" || missing=1
fi

[ "$missing" -eq 1 ] && die "install missing dependencies and re-run"

echo
echo "[log directory]"
log_dir="$(dirname "$LOG_FILE")"
if ! mkdir -p "$log_dir" 2>/dev/null; then
  echo "  need sudo for $log_dir — re-run as root, or create it manually and chown"
  exit 1
fi
mkdir -p "$OUTPUT_DIR" || die "cannot create OUTPUT_DIR: $OUTPUT_DIR"
echo "  log dir:    $log_dir"
echo "  output dir: $OUTPUT_DIR"

echo
echo "[crontab]"
CRON_LINE="0 3 * * * ${SCRIPT_DIR}/backup.sh >> ${log_dir}/cron.txt 2>&1"
TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -v "${SCRIPT_DIR}/backup.sh" > "$TMP" || true
echo "$CRON_LINE" >> "$TMP"
crontab "$TMP"
rm -f "$TMP"
echo "  installed: $CRON_LINE"
echo
echo "verify with:  crontab -l"
echo "manual run:   ${SCRIPT_DIR}/backup.sh"
