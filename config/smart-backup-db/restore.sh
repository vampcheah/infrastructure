#!/usr/bin/env bash
# smart-backup-db restore script.
# Reassembles split backup parts and pipes them into mysql or pg_restore.
# Refuses to target any database listed in config.sh unless --force is given.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

CONFIG_FILE="${SMART_BACKUP_CONFIG:-${SCRIPT_DIR}/config.sh}"
# Config is optional for restore (only needed for LOG_FILE and prod-db guard).
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=config.sh
  source "$CONFIG_FILE"
fi
: "${LOG_FILE:=/var/log/smart-backup-db/log.txt}"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/upload.sh
source "${SCRIPT_DIR}/lib/upload.sh"

usage() {
  cat <<'EOF'
Usage:
  restore.sh --source <local|s3> --path <path> --db <prefix>
             --target-db <name> [--type <mysql|postgres>]
             [--host H] [--port P] [--user U] [--force]

Required:
  --source       local: read from the local directory given in --path
                 s3:    aws s3 cp from --path to a temp dir first
  --path         local dir (e.g. /var/backups/db/20260412_030000)
                 or S3 URI (e.g. s3://bucket/db-backups/20260412_030000)
  --db           filename prefix, format: <target-name>__<db>
                 e.g. main-mysql__app
  --target-db    destination database (must already exist and be empty)

Optional:
  --type         mysql | postgres — auto-detected from file extension if omitted
  --host         default 127.0.0.1
  --port         default 3306 (mysql) or 5432 (postgres)
  --user         default root (mysql) or postgres (postgres)
  --force        allow --target-db to equal a production DB from config.sh

Examples:
  ./restore.sh --source local \
      --path /var/backups/db/20260412_030000 \
      --db main-mysql__app --target-db app_restored

  ./restore.sh --source s3 \
      --path s3://my-bucket/db-backups/20260412_030000 \
      --db main-pg__app --target-db app_restored --type postgres
EOF
}

SOURCE=""; PATH_ARG=""; DB_PREFIX=""; TARGET_DB=""; DB_TYPE=""
HOST="127.0.0.1"; PORT=""; USER_ARG=""; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --source)     SOURCE="$2"; shift 2 ;;
    --path)       PATH_ARG="$2"; shift 2 ;;
    --db)         DB_PREFIX="$2"; shift 2 ;;
    --target-db)  TARGET_DB="$2"; shift 2 ;;
    --type)       DB_TYPE="$2"; shift 2 ;;
    --host)       HOST="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --user)       USER_ARG="$2"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$SOURCE" ] || [ -z "$PATH_ARG" ] || [ -z "$DB_PREFIX" ] || [ -z "$TARGET_DB" ]; then
  usage >&2; exit 2
fi

# Now that we know we're actually doing work, initialise logging.
log_init

# Guard: refuse to restore into any DB that config.sh flags as production.
if [ "$FORCE" -ne 1 ] && [ -n "${TARGETS+x}" ]; then
  for target in "${TARGETS[@]}"; do
    IFS='|' read -r _t _n _h _p _u t_dbs <<<"$target"
    IFS=',' read -r -a prod_dbs <<<"$t_dbs"
    for d in "${prod_dbs[@]}"; do
      d="${d// /}"
      if [ "$d" = "$TARGET_DB" ]; then
        log_error "refusing to restore into production db '$TARGET_DB' (use --force to override)"
        exit 3
      fi
    done
  done
fi

# Stage S3 files locally if needed.
WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

case "$SOURCE" in
  local) SRC_DIR="$PATH_ARG" ;;
  s3)
    WORK_DIR="$(mktemp -d -t smart-restore-XXXXXX)"
    log_info "downloading ${PATH_ARG} -> ${WORK_DIR}"
    aws s3 cp --recursive "$PATH_ARG" "$WORK_DIR"
    SRC_DIR="$WORK_DIR"
    ;;
  *) log_error "invalid --source: $SOURCE"; exit 2 ;;
esac

if [ ! -d "$SRC_DIR" ]; then
  log_error "source directory not found: $SRC_DIR"
  exit 4
fi

# Collect parts, sorted so part-000, 001, 002 concatenate correctly.
shopt -s nullglob
parts=( "${SRC_DIR}/${DB_PREFIX}"*.part-* )
shopt -u nullglob

if [ "${#parts[@]}" -eq 0 ]; then
  log_error "no backup parts matching '${DB_PREFIX}' in ${SRC_DIR}"
  exit 4
fi

IFS=$'\n' parts=($(printf '%s\n' "${parts[@]}" | sort))
unset IFS

# Auto-detect type from filename if not explicit.
if [ -z "$DB_TYPE" ]; then
  case "${parts[0]}" in
    *.sql.gz.part-*) DB_TYPE="mysql" ;;
    *.dump.part-*)   DB_TYPE="postgres" ;;
    *) log_error "cannot auto-detect type from: ${parts[0]} (use --type)"; exit 2 ;;
  esac
fi

log_info "restoring type=${DB_TYPE} target=${TARGET_DB} parts=${#parts[@]} source=${SRC_DIR}"

rc=0
case "$DB_TYPE" in
  mysql)
    [ -z "$PORT" ] && PORT=3306
    [ -z "$USER_ARG" ] && USER_ARG="root"
    # Raw byte-splits of a single gzip stream -> cat parts | gunzip | mysql.
    set -o pipefail
    cat "${parts[@]}" | gunzip | mysql -h "$HOST" -P "$PORT" -u "$USER_ARG" "$TARGET_DB" || rc=$?
    ;;
  postgres)
    [ -z "$PORT" ] && PORT=5432
    [ -z "$USER_ARG" ] && USER_ARG="postgres"
    # pg_dump -Fc is already compressed; pg_restore reads the archive from stdin.
    set -o pipefail
    cat "${parts[@]}" | pg_restore -h "$HOST" -p "$PORT" -U "$USER_ARG" -d "$TARGET_DB" || rc=$?
    ;;
  *)
    log_error "unknown db type: $DB_TYPE"
    exit 2
    ;;
esac

if [ "$rc" -eq 0 ]; then
  log_ok "RESTORE OK: type=${DB_TYPE} target=${TARGET_DB} prefix=${DB_PREFIX}"
  exit 0
else
  log_error "RESTORE ERROR: type=${DB_TYPE} target=${TARGET_DB} prefix=${DB_PREFIX} rc=${rc}"
  exit "$rc"
fi
