#!/usr/bin/env bash
# S3 helpers. Requires: aws cli configured via `aws configure`.

s3_upload_dir() {
  # Args: local_dir s3_prefix (must end with /)
  local local_dir="$1" s3_prefix="$2"
  aws s3 cp --recursive "$local_dir" "$s3_prefix"
}

s3_list_prefixes() {
  # Returns the top-level "folders" (timestamps) under s3_root, one per line.
  local s3_root="$1"
  aws s3 ls "${s3_root%/}/" | awk '/ PRE /{print $2}' | sed 's#/$##'
}

s3_remove_prefix() {
  local s3_path="$1"
  aws s3 rm --recursive "$s3_path"
}
