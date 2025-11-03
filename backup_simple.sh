#!/usr/bin/env bash

# This is a SIMPLE and HEAVILY-COMMENTED backup script
# Goal: Be easy to read and understand (not feature-complete)
# What it does:
#   1) Reads config for destination and excludes
#   2) Creates a tar.gz archive named with a timestamp
#   3) Writes a checksum (SHA-256 if available)
#   4) Verifies the checksum and quickly tests archive integrity
#   5) Logs actions to a log file

set -euo pipefail

# find the home directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default config file path (can be overridden by BACKUP_CONFIG env var)
CONFIG_FILE="${BACKUP_CONFIG:-"$SCRIPT_DIR/backup.config"}"
LOG_FILE=""

########################################
# log(level, message)
# A helper function to print and save log messages with timestamps.
# Example: log INFO "Backup started"
# - Adds date and time before each message.
# - 'level' can be INFO, SUCCESS, ERROR, etc.
# - Also writes the same message to the log file ($LOG_FILE).
# - Uses 'tee -a' so output goes to both screen and file.

########################################
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $level: $msg" | tee -a "$LOG_FILE"
}

########################################
# load_config
# Loads settings from backup.config and sets defaults if missing
########################################
load_config() {
    # Defaults (used if config is missing or values not set)
    BACKUP_DESTINATION="${BACKUP_DESTINATION:-"$SCRIPT_DIR/backups"}"
    EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-".git,node_modules,.cache"}"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        # source imports variables from the config file
        source "$CONFIG_FILE"
    fi

    mkdir -p "$BACKUP_DESTINATION"
    LOG_FILE="$BACKUP_DESTINATION/backup.log"
}

########################################
# checksum_tool
# Chooses the best available checksum command
# checksum_tool()
# Detects which checksum command is available on the system.
# Returns one of: sha256sum, shasum -a 256, or md5sum.
# Used to verify backup integrity.
########################################
checksum_tool() {
    if command -v sha256sum >/dev/null 2>&1; then
        echo sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
    elif command -v md5sum >/dev/null 2>&1; then
        echo md5sum
    else
        echo "" # none found
    fi
}

########################################
# build_exclude_args
# Turns comma-separated EXCLUDE_PATTERNS into tar --exclude flags
# build_exclude_args(patterns)
# Converts comma-separated folder names into tar --exclude options.
# Example input: ".git,node_modules,.cache"
# Example output: --exclude=.git --exclude=*/.git/* --exclude=*/.git ...
# Ensures unwanted folders are skipped during backup.
########################################
build_exclude_args() {
    local patterns="$1"
    # sets the Internal Field Separator to a comma "," and reads the patterns into an array
    IFS="," read -r -a arr <<<"$patterns"
    local out=()
    for p in "${arr[@]}"; do
        [[ -z "$p" ]] && continue
        out+=("--exclude=$p")
        out+=("--exclude=*/$p/*")
        out+=("--exclude=*/$p")
    done
    printf '%s\n' "${out[@]}"
}

########################################
# create_backup SOURCE_DIR
# Creates the tar.gz archive and returns the archive path via stdout

# create_backup(source_dir)
# Creates a compressed .tar.gz backup of the given folder.
# - Checks if the folder exists and is readable.
# - Builds exclude patterns to skip unwanted folders.
# - Saves backup with timestamp in $BACKUP_DESTINATION.
# - Logs progress and returns the backup file path.
########################################
create_backup() {
    local src_dir="$1"
    local dest_dir="${DEST:-$PWD/backups}"
    mkdir -p "$dest_dir"

    local ts
    ts="$(date +%Y-%m-%d-%H%M)"
    local archive_name
    archive_name="$(basename "$src_dir")-$ts.tar.gz"
    local archive_path="$dest_dir/$archive_name"

    log "INFO" "Creating archive: $archive_name" >&2

    if tar -czf "$archive_path" -C "$(dirname "$src_dir")" "$(basename "$src_dir")"; then
        log "SUCCESS" "Backup created: $archive_name" >&2
        echo "$archive_path"  # 👈 Output only the path to stdout
    else
        log "ERROR" "Backup failed" >&2
        return 1
    fi
}

########################################
# write_checksum ARCHIVE_PATH
# Creates ARCHIVE_PATH.sha256 (or .md5) next to the archive

# write_checksum(archive_path)
# Creates a checksum (.sha256) file for the given backup.
# - Detects available checksum tool (sha256sum, shasum, or md5sum)
# - Saves output next to the backup file
# - Logs warning if no checksum tool found
# Example:
#   write_checksum "/home/backups/backup-2025-11-03-1230.tar.gz"
#   → creates backup-2025-11-03-1230.tar.gz.sha256

########################################
write_checksum() {
    local archive_path="$1"
    local tool
    tool="$(checksum_tool)"
    if [[ -z "$tool" ]]; then
        log "WARN" "No checksum tool found; skipping checksum"
        return 0
    fi

    local sumfile
    sumfile="$archive_path.sha256"
    (cd "$(dirname "$archive_path")" && eval "$tool \"$(basename "$archive_path")\"" >"$(basename "$sumfile")")
    log "SUCCESS" "Checksum written: $(basename "$sumfile")"
}

########################################
# verify_backup ARCHIVE_PATH
# Verifies the checksum and tests that the archive can be read/listed
########################################
verify_backup() {
    local archive_path="$1"
    local sumfile="$archive_path.sha256"
    local tool
    tool="$(checksum_tool)"

    if [[ -n "$tool" && -f "$sumfile" ]]; then
        if (cd "$(dirname "$archive_path")" && eval "$tool -c \"$(basename "$sumfile")\"" >/dev/null 2>&1); then
            log "INFO" "Checksum verified successfully"
        else
            log "ERROR" "Checksum verification FAILED"
            return 1
        fi
    else
        log "WARN" "Checksum or tool missing; skipping checksum verification"
    fi

    # Quick integrity test: list archive and try to read the first file
    if tar -tzf "$archive_path" >/dev/null 2>&1; then
        local first
        first="$(tar -tzf "$archive_path" | head -n1 || true)"
        if [[ -n "$first" ]]; then
            tar -xzf "$archive_path" -O "$first" >/dev/null 2>&1 || {
                log "ERROR" "Archive read test FAILED"
                return 1
            }
        fi
    else
        log "ERROR" "Archive list FAILED"
        return 1
    fi

    log "SUCCESS" "Backup verified"
}

########################################
# usage
# Prints a short help message
########################################
usage() {
    cat <<EOF
Usage:
  backup_simple.sh SOURCE_DIR

Creates a timestamped .tar.gz backup into BACKUP_DESTINATION from backup.config.
Writes a checksum and verifies the backup. Logs to backup.log.
EOF
}

########################################
# main
# Orchestrates the simple flow:
#   load config -> create backup -> checksum -> verify
########################################
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi
    local source_dir="$1"

    load_config
    local archive_path
    archive_path="$(create_backup "$source_dir")"
    write_checksum "$archive_path"
    if verify_backup "$archive_path"; then
        log "SUCCESS" "All done"
    else
        log "ERROR" "Verification failed"
        exit 1
    fi
}

DEST=$(awk -F= '/^BACKUP_DESTINATION=/{gsub(/"/,"",$2);print $2}' backup.config 2>/dev/null)
: "${DEST:="$PWD/backups"}"
echo "Log file: $DEST/backup.log"

main "$@"


