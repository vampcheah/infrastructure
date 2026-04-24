#!/usr/bin/env bash
# MySQL backend. Requires: mysqldump, mysql, gzip, split.
# Credentials come from ~/.my.cnf (chmod 600).

mysql_list_databases() {
  local host="$1" port="$2" user="$3"
  mysql -h "$host" -P "$port" -u "$user" -N -B -e "SHOW DATABASES" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'
}

mysql_backup_db() {
  # Args: host port user dbname out_prefix split_size
  # Writes: <out_prefix>.part-000 [.part-001 ...]
  local host="$1" port="$2" user="$3" db="$4" out_prefix="$5" split_size="$6"
  mysqldump \
      -h "$host" -P "$port" -u "$user" \
      --single-transaction --quick --routines --triggers \
      "$db" \
    | gzip \
    | split -b "$split_size" -d -a 3 - "${out_prefix}.part-"
}
