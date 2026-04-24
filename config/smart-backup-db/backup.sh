#!/usr/bin/env bash
# smart-backup-db main entry. Designed to be invoked by cron.
# Reads config.sh for targets and destination, streams dumps to compressed
# split files, optionally uploads to S3, then prunes old backups.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

CONFIG_FILE="${SMART_BACKUP_CONFIG:-${SCRIPT_DIR}/config.sh}"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "FATAL: config file not found: $CONFIG_FILE" >&2
  exit 2
fi
# shellcheck source=config.sh
source "$CONFIG_FILE"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/mysql.sh
source "${SCRIPT_DIR}/lib/mysql.sh"
# shellcheck source=lib/postgres.sh
source "${SCRIPT_DIR}/lib/postgres.sh"
# shellcheck source=lib/upload.sh
source "${SCRIPT_DIR}/lib/upload.sh"
# shellcheck source=lib/retention.sh
source "${SCRIPT_DIR}/lib/retention.sh"

log_init
trap 'log_error "backup.sh aborted at line $LINENO (exit=$?)"' ERR

TS="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${OUTPUT_DIR%/}/${TS}"
mkdir -p "$RUN_DIR"

log_info "=== run start ts=${TS} destination=${DESTINATION} ==="
START_EPOCH=$(date +%s)

ok_count=0
fail_count=0
# Tracks per-db retention: each entry is "name|db|days".
retention_plan=()

backup_one() {
  # Args: type name host port user db
  local type="$1" name="$2" host="$3" port="$4" user="$5" db="$6"
  local out_prefix rc=0

  case "$type" in
    mysql)    out_prefix="${RUN_DIR}/${name}__${db}.sql.gz" ;;
    postgres) out_prefix="${RUN_DIR}/${name}__${db}.dump"   ;;
    *)        log_error "unknown type: $type"; return 1 ;;
  esac

  # Run in a subshell so a pipeline failure doesn't abort the whole script.
  (
    set -o pipefail
    case "$type" in
      mysql)    mysql_backup_db    "$host" "$port" "$user" "$db" "$out_prefix" "$SPLIT_SIZE" ;;
      postgres) postgres_backup_db "$host" "$port" "$user" "$db" "$out_prefix" "$SPLIT_SIZE" ;;
    esac
  ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    log_error "backup failed: type=${type} name=${name} db=${db} rc=${rc}"
    rm -f "${out_prefix}".part-* 2>/dev/null || true
    return 1
  fi

  local parts size
  parts=$(find "$RUN_DIR" -maxdepth 1 -name "$(basename "${out_prefix}").part-*" | wc -l)
  size=$(du -cb "${out_prefix}".part-* 2>/dev/null | tail -1 | awk '{print $1}')
  log_ok "backup done: type=${type} name=${name} db=${db} parts=${parts} bytes=${size}"
  return 0
}

for target in "${TARGETS[@]}"; do
  IFS='|' read -r t_type t_name t_host t_port t_user t_dbs <<<"$target"
  db_list=()
  db_days=()

  case "$t_type" in
    mysql|postgres)
      if [ "$t_dbs" = "all" ]; then
        if [ "$t_type" = "mysql" ]; then
          mapfile -t db_list < <(mysql_list_databases    "$t_host" "$t_port" "$t_user") || true
        else
          mapfile -t db_list < <(postgres_list_databases "$t_host" "$t_port" "$t_user") || true
        fi
        # All auto-discovered dbs use the default retention.
        for _ in "${db_list[@]}"; do db_days+=("$RETENTION_DAYS"); done
      else
        IFS=',' read -r -a _raw_dbs <<<"$t_dbs"
        for entry in "${_raw_dbs[@]}"; do
          entry="${entry// /}"
          [ -z "$entry" ] && continue
          if [[ "$entry" == *:* ]]; then
            db_list+=("${entry%%:*}")
            db_days+=("${entry##*:}")
          else
            db_list+=("$entry")
            db_days+=("$RETENTION_DAYS")
          fi
        done
      fi
      ;;
    *)
      log_error "unknown target type: $t_type (name=$t_name)"
      fail_count=$((fail_count+1))
      continue
      ;;
  esac

  if [ "${#db_list[@]}" -eq 0 ]; then
    log_warn "target=${t_name} has no databases to back up"
    continue
  fi

  log_info "target=${t_name} type=${t_type} dbs=(${db_list[*]})"

  for i in "${!db_list[@]}"; do
    db="${db_list[$i]}"
    days="${db_days[$i]}"
    [ -z "$db" ] && continue
    retention_plan+=("${t_name}|${db}|${days}")
    if backup_one "$t_type" "$t_name" "$t_host" "$t_port" "$t_user" "$db"; then
      ok_count=$((ok_count+1))
    else
      fail_count=$((fail_count+1))
    fi
  done
done

# Upload to S3 if configured and something succeeded.
if [ "$DESTINATION" = "s3" ]; then
  if [ "$ok_count" -gt 0 ]; then
    log_info "uploading ${RUN_DIR} -> ${S3_BUCKET%/}/${TS}/"
    if s3_upload_dir "$RUN_DIR" "${S3_BUCKET%/}/${TS}/"; then
      log_ok "s3 upload done: ${S3_BUCKET%/}/${TS}/"
      rm -rf "$RUN_DIR"
    else
      log_error "s3 upload failed; keeping local copy at ${RUN_DIR}"
      fail_count=$((fail_count+1))
    fi
  else
    log_warn "no successful backups; skipping s3 upload"
    rmdir "$RUN_DIR" 2>/dev/null || true
  fi
fi

# Prune old backups — per-db retention, then sweep orphans with the default.
log_info "pruning old backups (default=${RETENTION_DAYS}d, entries=${#retention_plan[@]})"
pair_names=()
for entry in "${retention_plan[@]}"; do
  IFS='|' read -r p_name p_db p_days <<<"$entry"
  pair_names+=("${p_name}__${p_db}")
  prune_local_db "$OUTPUT_DIR" "$p_name" "$p_db" "$p_days" \
    || log_warn "local prune failed: ${p_name}/${p_db}"
  if [ "$DESTINATION" = "s3" ]; then
    prune_s3_db "$S3_BUCKET" "$p_name" "$p_db" "$p_days" \
      || log_warn "s3 prune failed: ${p_name}/${p_db}"
  fi
done
if [ "${#pair_names[@]}" -gt 0 ]; then
  prune_local_orphans "$OUTPUT_DIR" "$RETENTION_DAYS" "${pair_names[@]}" \
    || log_warn "local orphan prune had errors"
else
  log_warn "retention plan empty; skipping orphan prune to avoid wiping all files"
fi
prune_local_empty_dirs "$OUTPUT_DIR" || true
if [ "$DESTINATION" = "s3" ]; then
  prune_s3_empty_prefixes "$S3_BUCKET" || log_warn "s3 empty-prefix sweep had errors"
fi

DURATION=$(( $(date +%s) - START_EPOCH ))
if [ "$fail_count" -eq 0 ]; then
  log_ok "=== run end status=OK ok=${ok_count} fail=0 duration=${DURATION}s ==="
  exit 0
else
  log_error "=== run end status=FAIL ok=${ok_count} fail=${fail_count} duration=${DURATION}s ==="
  exit 1
fi
