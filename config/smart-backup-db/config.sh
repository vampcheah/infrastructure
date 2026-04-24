#!/usr/bin/env bash
# smart-backup-db configuration.
# This file is SOURCED by backup.sh / restore.sh — do not execute directly.
# Put real passwords in ~/.my.cnf and ~/.pgpass, not here.

# === Destination =============================================================
# "local" keeps backups in OUTPUT_DIR.
# "s3"    stages in OUTPUT_DIR, uploads to S3_BUCKET, then removes the local copy.
DESTINATION="local"

# Local staging / output directory. Always required.
OUTPUT_DIR="/var/backups/db"

# S3 bucket URI (only used when DESTINATION=s3). No trailing slash required.
S3_BUCKET="s3://my-bucket/db-backups"

# === Retention ===============================================================
# Default retention (days) — used for any database without a per-db override,
# and for auto-discovered databases when `databases=all`.
RETENTION_DAYS=7

# === Splitting ===============================================================
# Dumps are streamed through `split -b <SPLIT_SIZE>`; any unit split accepts
# works (e.g. 500M, 1G, 2G). If a dump is smaller than SPLIT_SIZE you get a
# single file ending in `.part-000`.
SPLIT_SIZE="256M"

# === Logging =================================================================
# Every run appends to this file. Both success and failure are recorded.
LOG_FILE="/var/log/smart-backup-db/log.txt"

# === Targets =================================================================
# Each entry: type|name|host|port|user|databases
#   type       mysql | postgres
#   name       arbitrary label; used in filenames and log lines
#   host,port  DB endpoint
#   user       DB user (password read from ~/.my.cnf or ~/.pgpass)
#   databases  comma-separated names, or the literal word "all" to auto-discover.
#              Per-db retention override: append ":N" to a name (e.g. app:30).
#              Names without ":N" fall back to RETENTION_DAYS.
TARGETS=(
  "mysql|main-mysql|infra-mysql|3306|root|app:30,analytics:7"
  "postgres|main-pg|infra-postgres|5432|postgres|all"
)
