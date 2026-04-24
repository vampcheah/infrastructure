#!/usr/bin/env bash
# Retention pruning for local and S3. Supports per-database retention.

prune_local_db() {
  # Args: dir name db days
  local dir="$1" name="$2" db="$3" days="$4"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -mtime +"$days" -name "${name}__${db}.*" -print -delete
}

prune_local_empty_dirs() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -type d -empty -delete
}

prune_local_orphans() {
  # Delete files not covered by any configured (name, db) pair, using the
  # default retention as a floor. Protects configured pairs via -not -name.
  local dir="$1" days="$2"; shift 2
  [ -d "$dir" ] || return 0
  local -a excludes=()
  local pair
  for pair in "$@"; do
    excludes+=( -not -name "${pair}.*" )
  done
  find "$dir" -type f -mtime +"$days" "${excludes[@]}" -print -delete
}

prune_s3_db() {
  # Args: s3_root name db days
  # Timestamp prefixes are YYYYMMDD_HHMMSS; delete matching files in old ones.
  local s3_root="$1" name="$2" db="$3" days="$4"
  local cutoff ts ts_date
  cutoff="$(date -d "${days} days ago" +%Y%m%d)"
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    ts_date="${ts:0:8}"
    [[ "$ts_date" =~ ^[0-9]{8}$ ]] || continue
    [ "$ts_date" -lt "$cutoff" ] || continue
    aws s3 rm --recursive --exclude "*" \
      --include "${name}__${db}.*" \
      "${s3_root%/}/${ts}/" >/dev/null || true
  done < <(s3_list_prefixes "$s3_root")
}

prune_s3_empty_prefixes() {
  # Remove timestamp prefixes that no longer contain any objects.
  local s3_root="$1" ts
  while IFS= read -r ts; do
    [ -z "$ts" ] && continue
    if [ -z "$(aws s3 ls "${s3_root%/}/${ts}/" 2>/dev/null)" ]; then
      aws s3 rm --recursive "${s3_root%/}/${ts}/" >/dev/null || true
    fi
  done < <(s3_list_prefixes "$s3_root")
}
