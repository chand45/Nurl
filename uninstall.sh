#!/bin/bash
# Nurl Uninstallation Script for Linux/macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.sh | bash -s -- --yes

set -eo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

NURL_HOME="$HOME/.nurl"
LEGACY_CONFIG_DIR="$HOME/.config/nushell"
ASSUME_YES=false
BACKUP_DIR=''
BACKUP_COMPLETE=false
BACKUP_DETACHED=false
WORK_ROOT=''
CONFIG_TEMPS=()
CONFIG_DISPLACED=''
CONFIG_DISPLACED_DEST=''
CONFIG_REPLACEMENT_PATHS=()
CONFIG_REPLACEMENT_BACKUPS=()
CONFIG_REPLACEMENT_CANDIDATES=()

for argument in "$@"; do
    case "$argument" in
        -y|--yes)
            ASSUME_YES=true
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $argument${NC}" >&2
            echo "Usage: uninstall.sh [-y|--yes]" >&2
            exit 2
            ;;
    esac
done
if [[ "${NURL_ASSUME_YES:-}" == '1' ]]; then
    ASSUME_YES=true
fi

trim_ascii_space() {
    local value="$1"
    value="${value#"${value%%[!$' \t']*}"}"
    value="${value%"${value##*[!$' \t']}"}"
    printf '%s' "$value"
}

resolve_config_path() {
    local path="$1"
    local target parent
    local depth=0
    while [[ -L "$path" ]]; do
        if (( depth >= 16 )); then
            return 1
        fi
        target="$(readlink "$path")" || return 1
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="$(dirname "$path")/$target"
        fi
        parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        path="$parent/$(basename "$path")"
        depth=$((depth + 1))
    done
    parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s' "$parent" "$(basename "$path")"
}

get_file_mode() {
    local path="$1"
    stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null
}

restore_displaced_config() {
    local displaced="$1"
    local destination="$2"
    if [[ ! -e "$displaced" ]]; then
        return 0
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        return 1
    fi
    if ln "$displaced" "$destination"; then
        rm -f "$displaced"
        return 0
    fi
    return 1
}

replace_config_safely() {
    local source="$1"
    local destination="$2"
    local snapshot="$3"
    local displaced
    LAST_CONFIG_BACKUP=''
    displaced="$(mktemp "$(dirname "$destination")/.config.nu.nurl.rollback.XXXXXX")"
    rm -f "$displaced"
    CONFIG_DISPLACED="$displaced"
    CONFIG_DISPLACED_DEST="$destination"
    mv "$destination" "$displaced"
    if ! cmp -s "$snapshot" "$displaced"; then
        restore_displaced_config "$displaced" "$destination" || true
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
        echo "Error: Nushell config changed during uninstall; the concurrent edit was preserved. The Nurl backup remains at $BACKUP_DIR." >&2
        return 1
    fi
    if ! ln "$source" "$destination"; then
        restore_displaced_config "$displaced" "$destination" || true
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
        echo "Error: Nushell config could not be updated. The Nurl backup remains at $BACKUP_DIR." >&2
        return 1
    fi
    rm -f "$source"
    LAST_CONFIG_BACKUP="$displaced"
    CONFIG_DISPLACED=''
    CONFIG_DISPLACED_DEST=''
}

canonicalize_directory_path() {
    local path="$1"
    local suffix=''
    local parent component
    while [[ ! -e "$path" ]]; do
        if [[ -L "$path" ]]; then
            return 1
        fi
        component="$(basename "$path")"
        if [[ "$component" == '.' || "$component" == '..' ]]; then
            return 1
        fi
        suffix="/$component$suffix"
        parent="$(dirname "$path")"
        if [[ "$parent" == "$path" ]]; then
            return 1
        fi
        path="$parent"
    done
    [[ -d "$path" ]] || return 1
    path="$(cd -P "$path" 2>/dev/null && pwd)" || return 1
    printf '%s%s' "$path" "$suffix"
}

read_config_records() {
    local source="$1"
    local LC_ALL=C
    local body=''
    local char='' line byte octal
    local pending_cr=false
    local CR=$'\r'
    local LF=$'\n'
    local scratch_root="${WORK_ROOT:-$HOME}"
    local byte_stream source_size decoded_count=0
    CONFIG_BODIES=()
    CONFIG_EOLS=()
    byte_stream="$(mktemp "$scratch_root/.nurl-config-bytes.XXXXXX")" || {
        echo -e "${RED}Error: Could not create a temporary byte stream for Nushell config: $source${NC}" >&2
        return 1
    }
    if ! od -An -v -tu1 "$source" > "$byte_stream"; then
        rm -f "$byte_stream"
        echo -e "${RED}Error: Could not read Nushell config bytes with od: $source${NC}" >&2
        return 1
    fi
    if ! source_size="$(wc -c < "$source")"; then
        rm -f "$byte_stream"
        echo -e "${RED}Error: Could not determine Nushell config byte count: $source${NC}" >&2
        return 1
    fi
    source_size="${source_size//[[:space:]]/}"
    while IFS= read -r line; do
        for byte in $line; do
            decoded_count=$((decoded_count + 1))
            if [[ "$byte" == '0' ]]; then
                rm -f "$byte_stream"
                echo -e "${RED}Error: Nushell config contains an unsupported NUL byte: $source${NC}" >&2
                return 1
            fi
            if [[ "$pending_cr" == true ]]; then
                if [[ "$byte" == '10' ]]; then
                    CONFIG_BODIES+=("$body")
                    CONFIG_EOLS+=("$CR$LF")
                    body=''
                    pending_cr=false
                    continue
                fi
                CONFIG_BODIES+=("$body")
                CONFIG_EOLS+=("$CR")
                body=''
                pending_cr=false
            fi
            if [[ "$byte" == '13' ]]; then
                pending_cr=true
            elif [[ "$byte" == '10' ]]; then
                CONFIG_BODIES+=("$body")
                CONFIG_EOLS+=("$LF")
                body=''
            else
                printf -v octal '%03o' "$byte"
                printf -v char '%b' "\\$octal"
                body+="$char"
            fi
        done
    done < "$byte_stream"
    rm -f "$byte_stream"
    if (( decoded_count != source_size )); then
        echo -e "${RED}Error: Nushell config byte read was incomplete: expected $source_size bytes, decoded $decoded_count.${NC}" >&2
        return 1
    fi
    if [[ "$pending_cr" == true ]]; then
        CONFIG_BODIES+=("$body")
        CONFIG_EOLS+=("$CR")
    elif [[ -n "$body" ]]; then
        CONFIG_BODIES+=("$body")
        CONFIG_EOLS+=('')
    fi
}

write_config_records() {
    local destination="$1"
    local index
    : > "$destination"
    for ((index = 0; index < ${#output_bodies[@]}; index++)); do
        printf '%s%s' "${output_bodies[$index]}" "${output_eols[$index]}" >> "$destination"
    done
}

is_legacy_source_line() {
    local line="${1%$'\r'}"
    line="$(trim_ascii_space "$line")"
    case "$line" in
        'source ~/.nurl/api.nu'|'source "~/.nurl/api.nu"'|'source $"($env.HOME)/.nurl/api.nu"')
            return 0
            ;;
    esac
    return 1
}

is_legacy_comment_line() {
    local line="${1%$'\r'}"
    line="$(trim_ascii_space "$line")"
    [[ "$line" == '# Nurl - Terminal API Client' ]]
}

prepare_clean_config() {
    local source="$1"
    local destination="$2"
    CLEAN_CONFIG_CHANGED=false

    read_config_records "$source"

    local output_bodies=()
    local output_eols=()
    local in_owned=false
    local removed=false
    local index
    local line clean
    for ((index = 0; index < ${#CONFIG_BODIES[@]}; index++)); do
        line="${CONFIG_BODIES[$index]}"
        clean="$(trim_ascii_space "$line")"
        if [[ "$clean" == '# >>> nurl >>>' ]]; then
            if [[ "$in_owned" == true ]]; then
                echo -e "${RED}Error: Nushell config contains nested Nurl sentinel blocks: $source${NC}" >&2
                return 1
            fi
            in_owned=true
            removed=true
            continue
        fi
        if [[ "$clean" == '# <<< nurl <<<' ]]; then
            if [[ "$in_owned" != true ]]; then
                echo -e "${RED}Error: Nushell config contains an unmatched Nurl sentinel: $source${NC}" >&2
                return 1
            fi
            in_owned=false
            if [[ -z "${CONFIG_EOLS[$index]}" && "$index" -eq $(( ${#CONFIG_BODIES[@]} - 1 )) && ${#output_bodies[@]} -gt 0 ]]; then
                local output_count=${#output_bodies[@]}
                output_eols[$((output_count - 1))]=''
            fi
            continue
        fi
        if [[ "$in_owned" == true ]]; then
            continue
        fi
        if is_legacy_source_line "$line"; then
            local output_count=${#output_bodies[@]}
            if (( output_count > 0 )) && is_legacy_comment_line "${output_bodies[$((output_count - 1))]}"; then
                unset 'output_bodies[output_count-1]'
                unset 'output_eols[output_count-1]'
                output_bodies=("${output_bodies[@]}")
                output_eols=("${output_eols[@]}")
            fi
            removed=true
            continue
        fi
        output_bodies+=("$line")
        output_eols+=("${CONFIG_EOLS[$index]}")
    done
    if [[ "$in_owned" == true ]]; then
        echo -e "${RED}Error: Nushell config contains an unterminated Nurl sentinel block: $source${NC}" >&2
        return 1
    fi

    if [[ "$removed" != true ]]; then
        return
    fi
    CLEAN_CONFIG_CHANGED=true
    write_config_records "$destination"
}

cleanup_on_failure() {
    local status=$?
    local index
    if [[ -n "$CONFIG_DISPLACED" && -e "$CONFIG_DISPLACED" ]]; then
        restore_displaced_config "$CONFIG_DISPLACED" "$CONFIG_DISPLACED_DEST" || true
    fi
    for ((index = ${#CONFIG_REPLACEMENT_PATHS[@]} - 1; index >= 0; index--)); do
        if [[ -e "${CONFIG_REPLACEMENT_BACKUPS[$index]}" ]] &&
           [[ -f "${CONFIG_REPLACEMENT_PATHS[$index]}" ]] &&
           cmp -s "${CONFIG_REPLACEMENT_CANDIDATES[$index]}" "${CONFIG_REPLACEMENT_PATHS[$index]}"; then
            rm -f "${CONFIG_REPLACEMENT_PATHS[$index]}"
            restore_displaced_config "${CONFIG_REPLACEMENT_BACKUPS[$index]}" "${CONFIG_REPLACEMENT_PATHS[$index]}" || true
        fi
    done
    if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
        rm -rf "$WORK_ROOT"
    fi
    local config_temp
    for config_temp in "${CONFIG_TEMPS[@]}"; do
        if [[ -n "$config_temp" && -e "$config_temp" ]]; then
            rm -f "$config_temp"
        fi
    done
    exit "$status"
}
trap cleanup_on_failure EXIT

echo -e "${BLUE}Uninstalling Nurl${NC}"
echo

if [[ -L "$NURL_HOME" ]]; then
    echo -e "${RED}Error: Refusing to uninstall through a symlinked Nurl root: $NURL_HOME${NC}" >&2
    exit 1
fi
NURL_HOME="$(canonicalize_directory_path "$NURL_HOME")" || {
    echo -e "${RED}Error: Could not resolve Nurl installation path: $NURL_HOME${NC}" >&2
    exit 1
}
if [[ ! -d "$NURL_HOME" ]]; then
    echo -e "${YELLOW}Nurl is not installed at $NURL_HOME${NC}"
    exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
    echo -e "${YELLOW}This will remove Nurl after creating and verifying a complete backup.${NC}"
    echo
    REPLY=''
    if [[ -t 0 ]]; then
        read -r -p "Continue? [y/N] " REPLY
    elif { exec 3<>/dev/tty; } 2>/dev/null; then
        printf 'Continue? [y/N] ' >&3
        IFS= read -r REPLY <&3
        exec 3>&-
    else
        echo -e "${RED}Error: Confirmation requires a terminal. Re-run with --yes, -y, or NURL_ASSUME_YES=1.${NC}" >&2
        exit 1
    fi
    if [[ ! "$REPLY" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

unsafe_entry="$(find "$NURL_HOME" \( -type l -o \( ! -type d ! -type f \) \) -print -quit)"
if [[ -n "$unsafe_entry" ]]; then
    echo -e "${RED}Error: Cannot create a verifiable backup while Nurl contains a link or special file: $unsafe_entry${NC}" >&2
    exit 1
fi

RESOLVED_CONFIG_DIR=''
if command -v nu >/dev/null 2>&1; then
    RESOLVED_CONFIG_DIR="$(
        nu --no-config-file -c '$nu.default-config-dir' 2>/dev/null \
            | sed -n '1p' \
            | tr -d '\r'
    )" || true
fi
if [[ -z "$RESOLVED_CONFIG_DIR" ]]; then
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        RESOLVED_CONFIG_DIR="$XDG_CONFIG_HOME/nushell"
    elif [[ "$(uname -s 2>/dev/null || true)" == 'Darwin' ]]; then
        RESOLVED_CONFIG_DIR="$HOME/Library/Application Support/nushell"
    else
        RESOLVED_CONFIG_DIR="$LEGACY_CONFIG_DIR"
    fi
fi

RAW_CONFIG_PATHS=("$RESOLVED_CONFIG_DIR/config.nu")
if [[ "$LEGACY_CONFIG_DIR/config.nu" != "${RAW_CONFIG_PATHS[0]}" ]]; then
    RAW_CONFIG_PATHS+=("$LEGACY_CONFIG_DIR/config.nu")
fi

WORK_ROOT="$(mktemp -d "$HOME/.nurl-uninstall.XXXXXX")"
CONFIG_PATHS=()
CONFIG_SOURCES=()
CONFIG_CANDIDATES=()
CONFIG_MODES=()
CONFIG_ORIGINALS=()
for raw_config_path in "${RAW_CONFIG_PATHS[@]}"; do
    if [[ ! -e "$raw_config_path" && ! -L "$raw_config_path" ]]; then
        continue
    fi
    config_path="$(resolve_config_path "$raw_config_path")" || {
        echo -e "${RED}Error: Nushell config link could not be resolved safely: $raw_config_path${NC}" >&2
        exit 1
    }
    if [[ -L "$config_path" || ! -f "$config_path" || ! -w "$config_path" ]]; then
        echo -e "${RED}Error: Refusing to replace a non-file Nushell config: $config_path${NC}" >&2
        exit 1
    fi
    case "$config_path" in
        "$NURL_HOME"|"$NURL_HOME"/*)
            echo -e "${RED}Error: Nushell config file must not resolve inside $NURL_HOME.${NC}" >&2
            exit 1
            ;;
    esac
    config_seen=false
    for existing_config_path in "${CONFIG_PATHS[@]}"; do
        if [[ "$existing_config_path" == "$config_path" ]]; then
            config_seen=true
            break
        fi
    done
    if [[ "$config_seen" == true ]]; then
        continue
    fi
    CONFIG_PATHS+=("$config_path")
    original="$WORK_ROOT/config-original-${#CONFIG_ORIGINALS[@]}.nu"
    cp -p "$config_path" "$original"
    candidate="$WORK_ROOT/config-${#CONFIG_CANDIDATES[@]}.nu"
    prepare_clean_config "$original" "$candidate"
    if [[ "$CLEAN_CONFIG_CHANGED" == true ]]; then
        CONFIG_SOURCES+=("$config_path")
        CONFIG_ORIGINALS+=("$original")
        CONFIG_CANDIDATES+=("$candidate")
        config_mode="$(get_file_mode "$config_path")" || {
            echo -e "${RED}Error: Could not determine Nushell config permissions: $config_path${NC}" >&2
            exit 1
        }
        CONFIG_MODES+=("$config_mode")
        config_temp="$(mktemp "$(dirname "$config_path")/.config.nu.nurl.XXXXXX")" || {
            echo -e "${RED}Error: Could not create an atomic temp beside Nushell config: $config_path${NC}" >&2
            exit 1
        }
        CONFIG_TEMPS+=("$config_temp")
        cp "$candidate" "$config_temp"
        chmod "$config_mode" "$config_temp"
    fi
done

BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$(mktemp -d "$HOME/.nurl-backup-$BACKUP_STAMP.XXXXXX")"
rmdir "$BACKUP_DIR"
echo "[1/3] Atomically creating a complete backup..."
SOURCE_SIGNATURE="$(cd "$NURL_HOME" && tar -cf - . | cksum)" || {
    echo -e "${RED}Error: Could not verify Nurl before backup; Nurl was not removed.${NC}" >&2
    exit 1
}
if ! mv "$NURL_HOME" "$BACKUP_DIR"; then
    echo -e "${RED}Error: Could not create the backup; Nurl was not removed.${NC}" >&2
    exit 1
fi
BACKUP_DETACHED=true
BACKUP_SIGNATURE="$(cd "$BACKUP_DIR" && tar -cf - . | cksum)" || true
if [[ "$SOURCE_SIGNATURE" != "$BACKUP_SIGNATURE" ]]; then
    if [[ ! -e "$NURL_HOME" ]]; then
        if mv "$BACKUP_DIR" "$NURL_HOME"; then
            BACKUP_DETACHED=false
        fi
    fi
    echo -e "${RED}Error: Backup verification failed; Nurl data was not deleted.${NC}" >&2
    exit 1
fi
BACKUP_COMPLETE=true
if [[ -e "$NURL_HOME" || -L "$NURL_HOME" ]]; then
    echo -e "${RED}Error: New Nurl data appeared during uninstall. It was left intact; the verified backup remains at $BACKUP_DIR.${NC}" >&2
    exit 1
fi

echo "[2/3] Nurl installation moved to the verified backup."
echo "[3/3] Cleaning owned Nushell config entries..."
for ((index = 0; index < ${#CONFIG_SOURCES[@]}; index++)); do
    config_path="${CONFIG_SOURCES[$index]}"
    replace_config_safely "${CONFIG_TEMPS[$index]}" "$config_path" "${CONFIG_ORIGINALS[$index]}"
    CONFIG_TEMPS[$index]=''
    CONFIG_REPLACEMENT_PATHS+=("$config_path")
    CONFIG_REPLACEMENT_BACKUPS+=("$LAST_CONFIG_BACKUP")
    CONFIG_REPLACEMENT_CANDIDATES+=("${CONFIG_CANDIDATES[$index]}")
done
completed_replacement_backups=("${CONFIG_REPLACEMENT_BACKUPS[@]}")
CONFIG_REPLACEMENT_PATHS=()
CONFIG_REPLACEMENT_BACKUPS=()
CONFIG_REPLACEMENT_CANDIDATES=()
for replacement_backup in "${completed_replacement_backups[@]}"; do
    rm -f "$replacement_backup"
done

echo
echo -e "${GREEN}Nurl uninstalled${NC}"
echo
echo "A complete, byte-verified backup was copied to:"
echo -e "  ${BLUE}$BACKUP_DIR${NC}"
echo "The backup includes all files that were present under $NURL_HOME,"
echo "including collections, chains, history, and NUON configuration."
