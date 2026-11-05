#!/usr/bin/env bash
# setup-swap.sh — 创建或复用 Swap 文件，配置开机启用及内核参数。
# Version: 1.2.2 | Updated: 2026-11-05
# 用法（root）：bash setup-swap.sh（默认 /swapfile、1G，内存不足 768MB 自动创建）。
# 指定容量：bash setup-swap.sh --size 2G --yes。
# 复用已有文件：bash setup-swap.sh --file /swap；重复执行会检查 fstab 和内核参数。
# 替换：bash setup-swap.sh --size 2G --replace --yes（会停用并删除其他活动 Swap 文件）。
# 同路径调整容量先删除旧文件；内存不足以安全停用时拒绝操作。
# 不管理 Swap 分区和 zram；已有其他 Swap 时默认不叠加创建。
# 需 Linux、Bash 4+；Btrfs 请先专门创建 Swap 文件，ZFS 不支持本方式。
# 其他 Swap 管理程序可能重建旧文件，请先停用；更多参数见 --help。

set -Eeuo pipefail

# Non-login PATH may not include sbin directories.
export PATH="${PATH}:/usr/sbin:/sbin"

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.2.2"

SWAP_FILE="/swapfile"
SWAP_SIZE="1G"
SWAPPINESS=10
VFS_CACHE_PRESSURE=50
readonly MEM_THRESHOLD_MB=768
readonly SYSCTL_CONF="/etc/sysctl.d/99-swap-optimization.conf"
readonly FSTAB="/etc/fstab"
readonly MIN_FREE_MARGIN_MB=512
readonly MIN_SWAP_MB=64
readonly SWAPOFF_MARGIN_MB=64

ASSUME_YES=0
FORCE=0
REPLACE=0
SIZE_GIVEN=0
SWAP_SIZE_MB=0
TARGET=""
CREATED_BY_US=0
ALLOC_METHOD=""
FSTAB_BACKED_UP=0
FSTAB_CHANGED=0
TMP_FILES=()

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# Swap state (read from /proc/swaps; works without util-linux)
# ------------------------------------------------------------------------------

# One line per active swap area: NAME<TAB>TYPE<TAB>SIZE_KB<TAB>USED_KB.
# Names are decoded (\040 -> space); swapfiles that were deleted are skipped.
swap_list() {
    local name type size used _
    while read -r name type size used _; do
        [ "$name" = "Filename" ] && continue
        name="$(printf '%b' "$name")"
        case "$name" in *" (deleted)") continue ;; esac
        printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$size" "$used"
    done < /proc/swaps
}

swap_names()       { swap_list | awk -F'\t' '{ print $1 }'; }
swap_file_names()  { swap_list | awk -F'\t' '$2 == "file" { print $1 }'; }

is_active_path() {
    swap_list | awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit(f ? 0 : 1) }'
}

is_swap_active() {
    is_active_path "$TARGET"
}

swap_used_kb() {
    swap_list | awk -F'\t' -v p="$1" '$1 == p { u = $4 } END { print u + 0 }'
}

# Free space (KiB) in all active swap areas except PATH.
swap_free_kb_except() {
    swap_list | awk -F'\t' -v p="$1" '$1 != p { r += $3 - $4 } END { print r + 0 }'
}

file_size_mb() {
    local bytes
    bytes="$(stat -c %s -- "$1" 2>/dev/null || printf '0')"
    printf '%s\n' "$((bytes / 1024 / 1024))"
}

# ------------------------------------------------------------------------------
# Cleanup / error handling
# ------------------------------------------------------------------------------

cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        if [ -n "$f" ] && [ -e "$f" ]; then
            rm -f -- "$f"
        fi
    done

    # Remove a half-created swapfile that this run created and never activated.
    if [ "$CREATED_BY_US" -eq 1 ] && [ -e "$SWAP_FILE" ] && ! is_swap_active; then
        rm -f -- "$SWAP_FILE"
        warn "Removed incomplete swapfile $SWAP_FILE created by this run."
    fi
    return 0
}
trap cleanup EXIT
trap 'rc=$?; printf "[ERROR] Command failed at line %s (exit code %s)\n" "$LINENO" "$rc" >&2' ERR
trap 'warn "Interrupted."; exit 130' INT
trap 'warn "Terminated."; exit 143' TERM

# Run a command with umask 077 without a subshell (a subshell would inherit the
# ERR trap and report every failure twice).
with_private_umask() {
    local old rc=0
    old="$(umask)"
    umask 077
    "$@" || rc=$?
    umask "$old"
    return "$rc"
}

# ------------------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------------------

usage() {
    cat <<EOF
setup-swap.sh v${SCRIPT_VERSION}

Usage:
  sudo bash ${SCRIPT_NAME} [options]

Options:
  -s, --size SIZE            Swapfile size, e.g. 512M, 1G, 2G (default: ${SWAP_SIZE})
  -f, --file PATH            Swapfile path (default: ${SWAP_FILE})
      --swappiness N         vm.swappiness, 0-200 (default: ${SWAPPINESS})
      --vfs-cache-pressure N vm.vfs_cache_pressure, 0-1000 (default: ${VFS_CACHE_PRESSURE})
  -r, --replace              Leave exactly one swapfile: SIZE at PATH
  -y, --yes                  Do not prompt (required when not on a terminal)
      --force                Skip container check; create even if other swap is active
  -h, --help                 Show this help
  -v, --version              Show version

Examples:
  sudo bash ${SCRIPT_NAME}                          # 1G at /swapfile
  sudo bash ${SCRIPT_NAME} --file /swap             # keep existing /swap, tune only
  sudo bash ${SCRIPT_NAME} --size 1G --replace --yes
EOF
}

need_value() {
    # need_value OPTION_NAME REMAINING_ARG_COUNT
    [ "$2" -ge 2 ] || die "Option $1 requires a value."
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -s|--size)
                need_value "$1" "$#"
                SWAP_SIZE="$2"
                SIZE_GIVEN=1
                shift 2
                ;;
            --size=*)
                SWAP_SIZE="${1#*=}"
                SIZE_GIVEN=1
                shift
                ;;
            -f|--file)
                need_value "$1" "$#"
                SWAP_FILE="$2"
                shift 2
                ;;
            --file=*)
                SWAP_FILE="${1#*=}"
                shift
                ;;
            --swappiness)
                need_value "$1" "$#"
                SWAPPINESS="$2"
                shift 2
                ;;
            --swappiness=*)
                SWAPPINESS="${1#*=}"
                shift
                ;;
            --vfs-cache-pressure)
                need_value "$1" "$#"
                VFS_CACHE_PRESSURE="$2"
                shift 2
                ;;
            --vfs-cache-pressure=*)
                VFS_CACHE_PRESSURE="${1#*=}"
                shift
                ;;
            -r|--replace)
                REPLACE=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                printf '%s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die "Unknown option: $1 (use --help)."
                ;;
        esac
    done
}

parse_size_mb() {
    local value="$1" number unit
    [[ "$value" =~ ^([0-9]{1,7})([MmGg]?)$ ]] || return 1
    number=$((10#${BASH_REMATCH[1]}))
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        G|g) printf '%s\n' "$((number * 1024))" ;;
        *)   printf '%s\n' "$number" ;;
    esac
}

# parse_int VALUE MAX -> prints VALUE as decimal (leading zeros are not octal)
parse_int() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    local n=$((10#$1))
    [ "$n" -le "$2" ] || return 1
    printf '%s\n' "$n"
}

validate_settings() {
    SWAP_SIZE_MB="$(parse_size_mb "$SWAP_SIZE")" \
        || die "Invalid --size '$SWAP_SIZE'. Examples: 512M, 1G, 2G."
    [ "$SWAP_SIZE_MB" -ge "$MIN_SWAP_MB" ] \
        || die "--size must be at least ${MIN_SWAP_MB}M."

    case "$SWAP_FILE" in
        /*/|/) die "--file must be a file path, not a directory: $SWAP_FILE" ;;
        /*) ;;
        *) die "--file must be an absolute path: $SWAP_FILE" ;;
    esac
    if [[ "$SWAP_FILE" =~ [[:space:]] ]]; then
        die "--file must not contain whitespace: $SWAP_FILE"
    fi

    SWAPPINESS="$(parse_int "$SWAPPINESS" 200)" \
        || die "--swappiness must be an integer between 0 and 200."
    VFS_CACHE_PRESSURE="$(parse_int "$VFS_CACHE_PRESSURE" 1000)" \
        || die "--vfs-cache-pressure must be an integer between 0 and 1000."
}

# This script manages swapFILES only. Refuse anything else at PATH.
check_target_path() {
    if [ -L "$SWAP_FILE" ]; then
        die "$SWAP_FILE is a symlink; pass the real path with --file."
    fi
    if [ -e "$SWAP_FILE" ] && [ ! -f "$SWAP_FILE" ]; then
        die "$SWAP_FILE is not a regular file. Partitions and zram are not managed by this script."
    fi
    # Canonical form, as the kernel shows it in /proc/swaps.
    TARGET="$(readlink -f -- "$SWAP_FILE" 2>/dev/null || printf '%s' "$SWAP_FILE")"
}

# ------------------------------------------------------------------------------
# Environment checks
# ------------------------------------------------------------------------------

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "Please run this script as root, for example: sudo bash ${SCRIPT_NAME}"
    fi
}

require_linux() {
    [ "$(uname -s)" = "Linux" ] || die "This script only supports Linux."
    [ -r /proc/swaps ] || die "/proc/swaps is not readable; is /proc mounted?"
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required (found ${BASH_VERSION})."
}

require_commands() {
    local cmd
    for cmd in awk grep swapon swapoff mkswap df readlink mktemp cmp stat dd; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

detect_container() {
    local container=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        container="$(systemd-detect-virt --container 2>/dev/null || true)"
    fi

    if [ -n "$container" ] && [ "$container" != "none" ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "Container environment detected ($container); continuing because of --force."
        else
            die "Container environment detected ($container). Containers usually cannot enable swap. Use --force to try anyway."
        fi
    fi
}

get_total_memory_mb() {
    awk '/^MemTotal:/ { printf "%.0f\n", $2 / 1024 }' /proc/meminfo
}

get_available_memory_kb() {
    awk '/^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 } END { print (a ? a : f) + 0 }' /proc/meminfo
}

confirm() {
    local prompt="$1"
    local answer=""

    printf '%s [y/N]: ' "$prompt"
    read -r answer || answer=""

    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

# ask_or_exit PROMPT: --yes continues, a terminal asks, anything else fails.
ask_or_exit() {
    if [ "$ASSUME_YES" -eq 1 ]; then
        log "--yes given; continuing."
        return 0
    fi
    if [ ! -t 0 ]; then
        die "Not running on a terminal; pass --yes to confirm: $1"
    fi
    if ! confirm "$1"; then
        log "Operation cancelled."
        exit 0
    fi
}

filesystem_type() {
    local dir="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o FSTYPE -T "$dir" 2>/dev/null | head -n1 || true
    else
        stat -f -c %T "$dir" 2>/dev/null || true
    fi
}

# preflight_filesystem_and_space [CREDIT_MB]
# CREDIT_MB = space freed before creation (an old file at PATH being replaced).
preflight_filesystem_and_space() {
    local credit_mb="${1:-0}" dir fstype avail need

    dir="$(dirname "$SWAP_FILE")"
    [ -d "$dir" ] || die "Directory does not exist: $dir"

    fstype="$(filesystem_type "$dir")"
    case "$fstype" in
        zfs)
            die "$dir is on ZFS, which does not support swapfiles. Use a zvol or a swap partition."
            ;;
        btrfs)
            die "$dir is on btrfs. Create the swapfile first with: btrfs filesystem mkswapfile --size ${SWAP_SIZE_MB}m $SWAP_FILE   then re-run this script to adopt it."
            ;;
        tmpfs|ramfs|overlay|overlayfs|nfs|nfs4|cifs|smb3|smbfs|fuse*)
            die "$dir is on '$fstype', which is not suitable for a swapfile."
            ;;
        "")
            warn "Could not determine the filesystem type of $dir; continuing."
            ;;
        *)
            log "Filesystem for $dir: $fstype"
            ;;
    esac

    avail="$(df -Pm "$dir" | awk 'NR == 2 { print $4 }')"
    avail="${avail:-0}"
    need=$((SWAP_SIZE_MB + MIN_FREE_MARGIN_MB))
    if [ $((avail + credit_mb)) -lt "$need" ]; then
        die "Not enough free space on $dir: ${avail}MB available (+${credit_mb}MB freed by replacement), ${need}MB required (${SWAP_SIZE_MB}MB swap + ${MIN_FREE_MARGIN_MB}MB margin)."
    fi
    log "Free space on $dir: ${avail}MB (required: ${need}MB)"
}

# ------------------------------------------------------------------------------
# Swap creation / adoption
# ------------------------------------------------------------------------------

allocate_swapfile() {
    # allocate_swapfile fallocate|dd
    local method="$1"

    rm -f -- "$SWAP_FILE"
    ALLOC_METHOD="$method"

    if [ "$method" = "fallocate" ]; then
        if with_private_umask fallocate -l "${SWAP_SIZE_MB}M" -- "$SWAP_FILE"; then
            return 0
        fi
        warn "fallocate failed, falling back to dd."
        rm -f -- "$SWAP_FILE"
        ALLOC_METHOD="dd"
    fi

    # status=progress is GNU-only; BusyBox dd rejects it.
    if dd if=/dev/zero of=/dev/null bs=1 count=0 status=progress >/dev/null 2>&1; then
        with_private_umask dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    else
        with_private_umask dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB"
    fi
}

create_swapfile() {
    local method="dd"
    if command -v fallocate >/dev/null 2>&1; then
        method="fallocate"
    fi

    log "Creating swapfile: $SWAP_FILE (${SWAP_SIZE_MB}MB)"
    CREATED_BY_US=1

    allocate_swapfile "$method"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"

    if ! swapon "$SWAP_FILE"; then
        if [ "$ALLOC_METHOD" = "fallocate" ]; then
            warn "swapon rejected the fallocate'd file (it may contain holes). Rebuilding with dd and retrying."
            allocate_swapfile dd
            chmod 600 "$SWAP_FILE"
            mkswap "$SWAP_FILE"
            swapon "$SWAP_FILE" || die "swapon failed for $SWAP_FILE."
        else
            die "swapon failed for $SWAP_FILE."
        fi
    fi

    CREATED_BY_US=0
    TARGET="$(readlink -f -- "$SWAP_FILE")"
    log "Swapfile $SWAP_FILE is active."
}

# Die unless PATH carries a swap signature (never delete data that is not swap).
verify_swap_signature() {
    local path="$1" signature=""

    command -v blkid >/dev/null 2>&1 || die "blkid not found; cannot verify $path. Please check it manually."
    signature="$(blkid -p -o value -s TYPE -- "$path" 2>/dev/null || true)"

    if [ "$signature" != "swap" ]; then
        die "$path exists but is not a valid swap file. To avoid destroying data the script will not touch it. Please inspect or remove it, then re-run."
    fi
}

adopt_existing_swapfile() {
    verify_swap_signature "$SWAP_FILE"

    warn "$SWAP_FILE exists, is a valid swap file but is not active. Activating it."
    chmod 600 "$SWAP_FILE"
    swapon "$SWAP_FILE" || die "swapon failed for existing $SWAP_FILE."
    log "Existing swapfile $SWAP_FILE is now active."
}

warn_size_mismatch() {
    local actual
    [ "$SIZE_GIVEN" -eq 1 ] || return 0
    actual="$(file_size_mb "$SWAP_FILE")"
    if [ "$actual" -ne "$SWAP_SIZE_MB" ]; then
        warn "$SWAP_FILE is ${actual}MB, not the requested ${SWAP_SIZE_MB}MB. Existing swapfiles are not resized; add --replace to rebuild it."
    fi
}

# ------------------------------------------------------------------------------
# --replace
# ------------------------------------------------------------------------------

# Refuse a swapoff whose pages would not fit into free RAM plus other free swap.
ensure_can_swapoff() {
    local path="$1" used_kb room_kb
    used_kb="$(swap_used_kb "$path")"
    room_kb=$(( $(get_available_memory_kb) + $(swap_free_kb_except "$path") - SWAPOFF_MARGIN_MB * 1024 ))

    if [ "$used_kb" -gt "$room_kb" ]; then
        die "Cannot safely deactivate $path: ${used_kb}KB of swap in use, only ${room_kb}KB of memory/other swap free. Free some memory and retry."
    fi
}

retire_swapfile() {
    local path="$1"

    if is_active_path "$path"; then
        ensure_can_swapoff "$path"
        log "Deactivating $path"
        swapoff "$path"
    fi
    fstab_remove_entry "$path"
    rm -f -- "$path"
    log "Removed old swapfile $path"
}

run_replace() {
    local keep_target=0 old=() f credit_mb=0

    [ "$SIZE_GIVEN" -eq 1 ] || warn "--replace without --size: the default ${SWAP_SIZE} is used."

    # 1. Is PATH already what we want?
    if is_swap_active && [ "$(file_size_mb "$SWAP_FILE")" -eq "$SWAP_SIZE_MB" ]; then
        keep_target=1
    elif [ -e "$SWAP_FILE" ] && ! is_swap_active; then
        # Inactive file at PATH: check BEFORE asking that it is swap, not data.
        verify_swap_signature "$SWAP_FILE"
    fi

    # 2. Every other active swapfile goes.
    while IFS= read -r f; do
        [ "$f" = "$TARGET" ] || old+=("$f")
    done < <(swap_file_names)

    if [ "$keep_target" -eq 1 ]; then
        if [ "${#old[@]}" -eq 0 ]; then
            log "--replace: $SWAP_FILE is already active at ${SWAP_SIZE_MB}MB and is the only swapfile; nothing to replace."
            return 0
        fi
        warn "--replace keeps $SWAP_FILE and will deactivate and delete: ${old[*]}"
        ask_or_exit "Remove these swapfiles?"
        for f in "${old[@]}"; do
            retire_swapfile "$f"
        done
        return 0
    fi

    # PATH has to be (re)built. Partitions/zram are not ours: do not stack on them.
    check_other_swap
    if [ -e "$SWAP_FILE" ] || [ "${#old[@]}" -gt 0 ]; then
        warn "--replace will deactivate and delete: $( [ -e "$SWAP_FILE" ] && printf '%s ' "$SWAP_FILE" )${old[*]:-}"
        ask_or_exit "Replace with ${SWAP_SIZE} swap at ${SWAP_FILE}?"
    else
        confirm_by_memory "$(get_total_memory_mb)"
    fi

    if [ -e "$SWAP_FILE" ]; then
        credit_mb="$(file_size_mb "$SWAP_FILE")"
    fi
    preflight_filesystem_and_space "$credit_mb"

    # Same path: the old file has to go before the new one can be created.
    if [ -e "$SWAP_FILE" ]; then
        retire_swapfile "$TARGET"
    fi

    create_swapfile
    # Persist the new swap now, so it survives a reboot even if a removal below fails.
    configure_fstab

    for f in ${old[@]+"${old[@]}"}; do
        retire_swapfile "$f"
    done
}

# ------------------------------------------------------------------------------
# /etc/fstab
# ------------------------------------------------------------------------------

fstab_has_entry() {
    awk -v p="$1" '
        $0 !~ /^[[:space:]]*#/ && $1 == p && $3 == "swap" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$FSTAB"
}

fstab_backup_once() {
    local backup
    [ "$FSTAB_BACKED_UP" -eq 0 ] || return 0
    backup="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$FSTAB" "$backup"
    FSTAB_BACKED_UP=1
    log "Backed up $FSTAB to $backup"
}

fstab_remove_entry() {
    local path="$1" tmp
    [ -f "$FSTAB" ] || return 0
    fstab_has_entry "$path" || return 0

    fstab_backup_once
    tmp="$(mktemp "${FSTAB}.XXXXXX")"
    TMP_FILES+=("$tmp")
    awk -v p="$path" '!($0 !~ /^[[:space:]]*#/ && $1 == p && $3 == "swap")' "$FSTAB" > "$tmp"
    # Write back through the existing file to keep its inode, owner and mode.
    cat -- "$tmp" > "$FSTAB"
    rm -f -- "$tmp"
    FSTAB_CHANGED=1
    log "Removed $path from $FSTAB."
}

configure_fstab() {
    log "Configuring $FSTAB"
    [ -f "$FSTAB" ] || die "$FSTAB not found."

    if fstab_has_entry "$SWAP_FILE"; then
        log "$FSTAB already contains $SWAP_FILE, skipping."
    else
        fstab_backup_once

        # If the last line has no trailing newline, appending would glue two lines together.
        if [ -s "$FSTAB" ] && [ -n "$(tail -c1 "$FSTAB")" ]; then
            printf '\n' >> "$FSTAB"
        fi

        printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> "$FSTAB"
        FSTAB_CHANGED=1
        log "Added $SWAP_FILE to $FSTAB."
    fi

    if [ "$FSTAB_CHANGED" -eq 1 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi
    FSTAB_CHANGED=0
}

# ------------------------------------------------------------------------------
# sysctl
# ------------------------------------------------------------------------------

render_sysctl_config() {
    cat <<EOF
# Managed by setup-swap.sh
vm.swappiness=$SWAPPINESS
vm.vfs_cache_pressure=$VFS_CACHE_PRESSURE
EOF
}

warn_later_sysctl_overrides() {
    local pattern='^[[:space:]]*-?[[:space:]]*vm[./](swappiness|vfs_cache_pressure)[[:space:]]*='
    local ours our_real f real base matches found=""
    local -A seen=()

    ours="$(basename "$SYSCTL_CONF")"
    our_real="$(readlink -f "$SYSCTL_CONF")"

    for f in /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf \
             /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf /etc/sysctl.conf; do
        [ -e "$f" ] || continue
        real="$(readlink -f "$f")"
        [ "$real" != "$our_real" ] || continue
        [ -z "${seen[$real]:-}" ] || continue
        seen["$real"]=1

        base="${f##*/}"
        if [ "$f" != "/etc/sysctl.conf" ]; then
            # Only files that load after ours can override it.
            [ "$base" != "$ours" ] || continue
            [ "$(printf '%s\n%s\n' "$ours" "$base" | LC_ALL=C sort | tail -n1)" = "$base" ] || continue
        fi

        matches="$(grep -HnE "$pattern" "$real" 2>/dev/null || true)"
        if [ -n "$matches" ]; then
            found+="${matches}"$'\n'
        fi
    done

    if [ -n "$found" ]; then
        warn "Other sysctl files set vm.swappiness / vm.vfs_cache_pressure and load after $ours; they may override these values at boot:"
        sed 's/^/  /' <<< "${found%$'\n'}" >&2
    fi
}

configure_sysctl() {
    local tmp out

    log "Configuring swap-related kernel parameters"

    install -d -m 755 "$(dirname "$SYSCTL_CONF")"
    tmp="$(mktemp "$(dirname "$SYSCTL_CONF")/.99-swap-optimization.XXXXXX")"
    TMP_FILES+=("$tmp")
    render_sysctl_config > "$tmp"
    chmod 644 "$tmp"

    if [ -f "$SYSCTL_CONF" ] && cmp -s "$tmp" "$SYSCTL_CONF"; then
        rm -f -- "$tmp"
        log "$SYSCTL_CONF is already up to date."
    else
        mv -f -- "$tmp" "$SYSCTL_CONF"
        log "Wrote $SYSCTL_CONF"
    fi

    # Apply only our own file (not `sysctl --system`, which re-applies every sysctl file).
    if out="$(sysctl -p "$SYSCTL_CONF" 2>&1)"; then
        log "Applied vm.swappiness=$SWAPPINESS"
        log "Applied vm.vfs_cache_pressure=$VFS_CACHE_PRESSURE"
    else
        warn "Could not apply sysctl settings now: $out"
        warn "They are saved in $SYSCTL_CONF and will be used at the next boot."
    fi

    warn_later_sysctl_overrides
}

# ------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------

show_result() {
    log "Swap setup completed."

    printf '\n'
    if command -v free >/dev/null 2>&1; then
        free -h || true
        printf '\n'
    fi

    cat /proc/swaps

    printf '\n'
    printf 'vm.swappiness=%s\n' "$(cat /proc/sys/vm/swappiness)"
    printf 'vm.vfs_cache_pressure=%s\n' "$(cat /proc/sys/vm/vfs_cache_pressure)"
}

# ------------------------------------------------------------------------------
# Decisions for creating a NEW swapfile
# ------------------------------------------------------------------------------

# Do not stack a new swapfile on other active swap unless --force.
# With --replace, other swapfiles are removed later, so only partitions/zram count.
check_other_swap() {
    local others files

    if [ "$REPLACE" -eq 1 ]; then
        others="$(swap_list | awk -F'\t' -v t="$TARGET" '$1 != t && $2 != "file" { print $1 }')"
    else
        others="$(swap_names | grep -vxF -- "$TARGET" || true)"
    fi
    [ -n "$others" ] || return 0

    if [ "$FORCE" -eq 1 ]; then
        warn "Other swap is already active; creating $SWAP_FILE in addition because of --force:"
        sed 's/^/  /' <<< "$others" >&2
        return 0
    fi

    log "Other swap is already active, so no new swapfile will be created:"
    sed 's/^/  /' <<< "$others"

    files="$(swap_file_names | grep -vxF -- "$TARGET" || true)"
    if [ "$REPLACE" -eq 0 ] && [ -n "$files" ]; then
        log "Keep that swapfile, only tune fstab/sysctl : --file $(head -n1 <<< "$files")"
        log "Replace it with ${SWAP_SIZE} at ${SWAP_FILE}            : --replace"
    fi
    log "Add ${SWAP_FILE} on top of it                : --force"
    exit 0
}

confirm_by_memory() {
    local total_mem_mb="$1"

    if [ "$total_mem_mb" -lt "$MEM_THRESHOLD_MB" ]; then
        log "Memory is less than ${MEM_THRESHOLD_MB}MB. Swap setup will continue automatically."
        return 0
    fi

    warn "Memory is greater than or equal to ${MEM_THRESHOLD_MB}MB."
    ask_or_exit "Do you still want to create and enable ${SWAP_SIZE} swap at ${SWAP_FILE}?"
}

main() {
    parse_args "$@"
    require_root
    require_linux
    require_commands
    validate_settings
    detect_container
    check_target_path

    local total_mem_mb
    total_mem_mb="$(get_total_memory_mb)"
    log "Detected total memory: ${total_mem_mb}MB"

    if [ "$REPLACE" -eq 1 ]; then
        run_replace
    elif is_swap_active; then
        log "$SWAP_FILE is already active; verifying configuration."
        warn_size_mismatch
    elif [ -e "$SWAP_FILE" ]; then
        adopt_existing_swapfile
        warn_size_mismatch
    else
        check_other_swap
        confirm_by_memory "$total_mem_mb"
        preflight_filesystem_and_space 0
        create_swapfile
    fi

    configure_fstab
    configure_sysctl
    show_result
}

main "$@"
