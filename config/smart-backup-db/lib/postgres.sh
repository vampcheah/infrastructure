#!/usr/bin/env bash
# PostgreSQL backend. Requires: pg_dump, psql, pg_restore, split.
# Credentials come from ~/.pgpass (chmod 600).

postgres_list_databases() {
  local host="$1" port="$2" user="$3"
  psql -h "$host" -p "$port" -U "$user" -At -c \
    "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres';"
}

postgres_backup_db() {
  # Args: host port user dbname out_prefix split_size
  # Uses -Fc (custom format) which is already compressed — no gzip pipeline.
  local host="$1" port="$2" user="$3" db="$4" out_prefix="$5" split_size="$6"
  pg_dump -h "$host" -p "$port" -U "$user" -Fc "$db" \
    | split -b "$split_size" -d -a 3 - "${out_prefix}.part-"
}
