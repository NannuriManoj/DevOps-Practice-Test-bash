#!/usr/bin/env bash

# This is a SIMPLE and HEAVILY-COMMENTED backup script
# Goal: Be easy to read and understand (not feature-complete)
# Added features:
#  - Dry-run mode (--dry-run)
#  - Lock file to prevent concurrent runs
#  - Rotation: keep last N daily/weekly/monthly backups
#  - Disk space check before backup
#  - Better checksum naming (.sha256 or .md5 depending on available tool)
#  - Cleanup on interruption (partial archives removed)
#
# Usage examples:
#   ./backup_simple.sh /path/to/source
#   ./backup_simple.sh --dry-run /path/to/source
#   ./backup_simple.sh --list
#   ./backup_simple.sh --restore backup-2024-11-03-1430.tar.gz --to /tmp/restore_test

set -euo pipefail

# find the home directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default config file path (can be overridden by BACKUP_CONFIG env var)
CONFIG_FILE="${BACKUP_CONFIG:-"$SCRIPT_DIR/backup.config"}"
LOG_FILE=""
LOCK_FILE="/tmp/backup_simple.lock"
DRY_RUN=false

########################################
# log(level, message)
# A helper function to print and save log messages with timestamps.
########################################
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$ts] $level: $msg" | tee -a "$LOG_FILE"
    else
        echo "[$ts] $level: $msg"
    fi
}

########################################
# load_config
# Loads settings from backup.config and sets defaults if missing
########################################
load_config() {
    # Defaults (used if config is missing or values not set)
    BACKUP_DESTINATION="${BACKUP_DESTINATION:-"$SCRIPT_DIR/backups"}"
    EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-".git,node_modules,.cache"}"
    DAILY_KEEP="${DAILY_KEEP:-7}"
    WEEKLY_KEEP="${WEEKLY_KEEP:-4}"
    MONTHLY_KEEP="${MONTHLY_KEEP:-3}"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    mkdir -p "$BACKUP_DESTINATION"
    LOG_FILE="$BACKUP_DESTINATION/backup.log"
}

########################################
# checksum_tool
# Chooses the best available checksum command
# Returns a command string (e.g. "sha256sum" or "shasum -a 256" or "md5sum")
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
# build_exclude_args(patterns)
# Converts comma-separated folder names into tar --exclude options.
# Returns one argument per line (so callers can read into an array).
########################################
build_exclude_args() {
    local patterns="$1"
    IFS="," read -r -a arr <<<"$patterns"
    for p in "${arr[@]}"; do
        [[ -z "$p" ]] && continue
        # exclude pattern itself and occurrences under any subdir
        printf '%s\n' "--exclude=$p" "--exclude=*/$p/*" "--exclude=*/$p"
    done
}

########################################
# acquire_lock / release_lock
# Prevents multiple runs by using a lock file.
########################################
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
            log "ERROR" "Another backup process (PID $pid) is already running. Exiting."
            exit 1
        else
            log "WARN" "Stale lock file found; removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo "$$" >"$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE" || true
}

########################################
# cleanup_partial ARCHIVE_PATH
# Remove partial archive if script aborted during creation.
########################################
cleanup_partial() {
    local archive_path="$1"
    if [[ -n "${archive_path:-}" && -f "$archive_path" ]]; then
        rm -f "$archive_path"
        log "INFO" "Removed partial archive: $(basename "$archive_path")"
    fi
}

########################################
# estimate_size_and_check_space SOURCE_DIR DEST_DIR
# Ensure destination has at least source size available (simple check).
########################################
estimate_size_and_check_space() {
    local src="$1"
    local dest="$2"

    # size in bytes
    local need
    need=$(du -s -B1 "$src" 2>/dev/null | awk '{print $1}' || echo 0)
    if [[ "$need" -eq 0 ]]; then
        # could be empty folder or du failed; allow proceed but warn
        log "WARN" "Could not determine source size (or empty). Skipping strict space check."
        return 0
    fi

    # available on dest (in bytes)
    local avail
    avail=$(df --output=avail -B1 "$dest" 2>/dev/null | tail -n1 || echo 0)
    if [[ -z "$avail" ]]; then
        log "WARN" "Could not determine available disk space on destination."
        return 0
    fi

    # Add some buffer (10%)
    local buffer
    buffer=$((need / 10))
    local required
    required=$((need + buffer))

    if (( avail < required )); then
        log "ERROR" "Not enough disk space on destination. Required ~${required} bytes, available ${avail} bytes."
        return 1
    fi
    return 0
}

########################################
# create_backup SOURCE_DIR
# Creates the tar.gz archive and returns the archive path via stdout
########################################
create_backup() {
    local src_dir="$1"
    local dest_dir="${BACKUP_DESTINATION:-$PWD/backups}"
    mkdir -p "$dest_dir"

    # Check source exists and is readable
    if [[ ! -d "$src_dir" ]]; then
        log "ERROR" "Source folder not found: $src_dir"
        return 2
    fi
    if [[ ! -r "$src_dir" ]]; then
        log "ERROR" "Cannot read source folder (permission denied): $src_dir"
        return 2
    fi

    # Disk space check
    if ! estimate_size_and_check_space "$src_dir" "$dest_dir"; then
        return 2
    fi

    local ts
    ts="$(date +%Y-%m-%d-%H%M)"
    local archive_name
    archive_name="$(basename "$src_dir")-$ts.tar.gz"
    local archive_path="$dest_dir/$archive_name"

    # Build exclude args into an array
    mapfile -t excl <<<"$(build_exclude_args "$EXCLUDE_PATTERNS")"

    log "INFO" "Creating archive: $archive_name"

    # If dry-run: just print what we'd do
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry run: would create archive at $archive_path"
        log "INFO" "Dry run: exclude patterns: $EXCLUDE_PATTERNS"
        log "INFO" "Dry run: tar -czf $archive_path -C $(dirname "$src_dir") ${excl[*]} $(basename "$src_dir")"
        echo "$archive_path"
        return 0
    fi

    # Ensure partials removed on error
    trap 'cleanup_partial "$archive_path"; release_lock' ERR

    if tar -czf "$archive_path" -C "$(dirname "$src_dir")" "${excl[@]}" "$(basename "$src_dir")"; then
        log "SUCCESS" "Backup created: $archive_name"
        # clear the ERR trap (we'll manage cleanup via main trap)
        trap - ERR
        echo "$archive_path"  # Output only the path to stdout
    else
        log "ERROR" "Backup failed"
        cleanup_partial "$archive_path"
        return 1
    fi
}

########################################
# write_checksum ARCHIVE_PATH
# Creates ARCHIVE_PATH.sha256 (or .md5) next to the archive
########################################
write_checksum() {
    local archive_path="$1"
    local tool
    tool="$(checksum_tool)"
    if [[ -z "$tool" ]]; then
        log "WARN" "No checksum tool found; skipping checksum"
        return 0
    fi

    # decide extension
    local ext
    if [[ "$tool" == "md5sum" ]]; then
        ext="md5"
    else
        ext="sha256"
    fi

    local sumfile
    sumfile="$archive_path.$ext"
    (cd "$(dirname "$archive_path")" && eval "$tool \"$(basename "$archive_path")\"" >"$(basename "$sumfile")")
    log "SUCCESS" "Checksum written: $(basename "$sumfile")"
}

########################################
# verify_backup ARCHIVE_PATH
# Verifies the checksum and tests that the archive can be read/listed
########################################
verify_backup() {
    local archive_path="$1"
    local tool
    tool="$(checksum_tool)"

    # find matching checksum file (try .sha256 then .md5)
    local sumfile=""
    if [[ -f "$archive_path.sha256" ]]; then
        sumfile="$archive_path.sha256"
    elif [[ -f "$archive_path.md5" ]]; then
        sumfile="$archive_path.md5"
    fi

    if [[ -n "$tool" && -n "$sumfile" ]]; then
        # mapping: if tool is "shasum -a 256" or "sha256sum" use -c; md5sum also supports -c
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
            if ! tar -xzf "$archive_path" -O "$first" >/dev/null 2>&1; then
                log "ERROR" "Archive read test FAILED"
                return 1
            fi
        fi
    else
        log "ERROR" "Archive list FAILED"
        return 1
    fi

    log "SUCCESS" "Backup verified"
    return 0
}

########################################
# delete_old_backups
# Keeps last DAILY_KEEP daily, WEEKLY_KEEP weekly, MONTHLY_KEEP monthly backups.
# Strategy:
#  - iterate backups newest -> oldest
#  - keep the first backup seen for each day up to DAILY_KEEP
#  - then keep first backup seen for each week up to WEEKLY_KEEP
#  - then keep first backup seen for each month up to MONTHLY_KEEP
#  - delete the rest
########################################
delete_old_backups() {
    local dest="$BACKUP_DESTINATION"
    local daily_keep="${DAILY_KEEP}"
    local weekly_keep="${WEEKLY_KEEP}"
    local monthly_keep="${MONTHLY_KEEP}"

    log "INFO" "Starting retention cleanup (daily:$daily_keep weekly:$weekly_keep monthly:$monthly_keep) in $dest"

    # Collect archives (only .tar.gz)
    mapfile -t archives < <(find "$dest" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort -r)

    declare -A seen_days
    declare -A seen_weeks
    declare -A seen_months
    local daily_count=0
    local weekly_count=0
    local monthly_count=0

    local to_delete=()

    for name in "${archives[@]}"; do
        # extract the timestamp part: expect pattern like name-YYYY-MM-DD-HHMM.tar.gz
        # find last occurrence of YYYY-MM-DD-HHMM
        if ! ds="$(echo "$name" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}' || true)"; then
            ds=""
        fi

        local day_key week_key month_key epoch dt_formatted
        if [[ -n "$ds" ]]; then
            local day="${ds:0:10}"
            local hour="${ds:11:2}"
            local minute="${ds:13:2}"
            dt_formatted="$day $hour:$minute"
            # compute week key (ISO year-week)
            if week_key=$(date -d "$dt_formatted" +%Y-%V 2>/dev/null); then
                :
            else
                week_key="$day"
            fi
            month_key=$(date -d "$dt_formatted" +%Y-%m 2>/dev/null || echo "${day:0:7}")
            day_key="$day"
        else
            # could not parse date — put into deletion list (old format)
            to_delete+=("$name")
            continue
        fi

        # Daily
        if [[ -z "${seen_days[$day_key]:-}" && $daily_count -lt $daily_keep ]]; then
            seen_days[$day_key]=1
            ((daily_count++))
            continue
        fi

        # Weekly
        if [[ -z "${seen_weeks[$week_key]:-}" && $weekly_count -lt $weekly_keep ]]; then
            seen_weeks[$week_key]=1
            ((weekly_count++))
            continue
        fi

        # Monthly
        if [[ -z "${seen_months[$month_key]:-}" && $monthly_count -lt $monthly_keep ]]; then
            seen_months[$month_key]=1
            ((monthly_count++))
            continue
        fi

        # Otherwise mark for deletion
        to_delete+=("$name")
    done

    if [[ "${#to_delete[@]}" -eq 0 ]]; then
        log "INFO" "No backups to delete by retention policy."
        return 0
    fi

    for f in "${to_delete[@]}"; do
        local full="$dest/$f"
        if [[ "$DRY_RUN" == true ]]; then
            log "INFO" "Dry run: would delete $f"
        else
            if rm -f "$full"; then
                # also remove possible checksum file(s)
                rm -f "$full".sha256 "$full".md5 || true
                log "INFO" "Deleted old backup: $f"
            else
                log "WARN" "Failed to delete $f"
            fi
        fi
    done
}

########################################
# list_backups
# Lists backups with sizes and dates
########################################
list_backups() {
    local dest="$BACKUP_DESTINATION"
    echo "Backups in $dest:"
    ls -lh --time-style=long-iso "$dest"/*.tar.gz 2>/dev/null || echo "  (no backups)"
}

########################################
# restore_backup ARCHIVE --to DEST_DIR
########################################
restore_backup() {
    local archive="$1"
    local to="$2"
    if [[ ! -f "$archive" ]]; then
        log "ERROR" "Backup to restore not found: $archive"
        return 1
    fi
    mkdir -p "$to"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry run: would restore $archive to $to"
        return 0
    fi
    if tar -xzf "$archive" -C "$to"; then
        log "SUCCESS" "Restored $archive to $to"
    else
        log "ERROR" "Restore failed"
        return 1
    fi
}

########################################
# usage
########################################
usage() {
    cat <<EOF
Usage:
  backup_simple.sh [--dry-run] SOURCE_DIR
  backup_simple.sh --list
  backup_simple.sh --restore ARCHIVE.tar.gz --to DEST_DIR

Creates a timestamped .tar.gz backup into BACKUP_DESTINATION from backup.config.
Writes a checksum and verifies the backup. Logs to backup.log.
EOF
}

########################################
# main
########################################
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    # parse simple flags
    local cmd="$1"
    if [[ "$cmd" == "--dry-run" ]]; then
        DRY_RUN=true
        shift || true
    fi

    # support --list early (no lock needed)
    if [[ "${1:-}" == "--list" ]]; then
        load_config
        list_backups
        exit 0
    fi

    if [[ "${1:-}" == "--restore" ]]; then
        if [[ $# -lt 3 ]]; then
            usage
            exit 1
        fi
        local archive="$2"
        if [[ "$3" != "--to" || -z "${4:-}" ]]; then
            usage
            exit 1
        fi
        load_config
        if [[ "$DRY_RUN" == true ]]; then
            log "INFO" "Dry run: restore $archive to $4"
            exit 0
        fi
        restore_backup "$archive" "$4"
        exit $?
    fi

    local source_dir="$1"

    load_config

    # Acquire lock (unless listing)
    acquire_lock
    # ensure we always release lock on exit
    trap 'release_lock' EXIT

    log "INFO" "Starting backup of $source_dir"
    log "INFO" "Destination: $BACKUP_DESTINATION"
    log "INFO" "Excludes: $EXCLUDE_PATTERNS"
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry run mode enabled"
    fi

    local archive_path
    archive_path="$(create_backup "$source_dir")" || {
        local rc=$?
        release_lock
        exit $rc
    }

    # write checksum (skips if no tool)
    write_checksum "$archive_path"

    # verify
    if verify_backup "$archive_path"; then
        log "SUCCESS" "All done for $(basename "$archive_path")"
    else
        log "ERROR" "Verification failed for $(basename "$archive_path")"
        release_lock
        exit 1
    fi

    # rotation cleanup
    delete_old_backups

    release_lock
}

# Print where log will be (after config load), but we must load config first to know LOG_FILE
# We load config just to show the path without running main
load_config
echo "Log file: $LOG_FILE"

main "$@"
