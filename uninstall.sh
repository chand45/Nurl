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
WORK_ROOT=''

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

    local bodies=()
    local line clean
    while IFS= read -r line || [[ -n "$line" ]]; do
        bodies+=("$line")
    done < "$source"

    local trailing_newline=false
    if [[ -s "$source" ]] && [[ "$(tail -c 1 "$source" | od -An -t u1 | tr -d '[:space:]')" == '10' ]]; then
        trailing_newline=true
    fi

    local output=()
    local in_owned=false
    local removed=false
    local index
    for ((index = 0; index < ${#bodies[@]}; index++)); do
        line="${bodies[$index]}"
        clean="${line%$'\r'}"
        clean="$(trim_ascii_space "$clean")"
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
            if [[ "$trailing_newline" != true && "$index" -eq $(( ${#bodies[@]} - 1 )) && ${#output[@]} -gt 0 ]]; then
                local output_count=${#output[@]}
                output[$((output_count - 1))]="${output[$((output_count - 1))]%$'\r'}"
            fi
            continue
        fi
        if [[ "$in_owned" == true ]]; then
            continue
        fi
        if is_legacy_source_line "$line"; then
            local output_count=${#output[@]}
            if (( output_count > 0 )) && is_legacy_comment_line "${output[$((output_count - 1))]}"; then
                unset 'output[output_count-1]'
                output=("${output[@]}")
            fi
            removed=true
            continue
        fi
        output+=("$line")
    done
    if [[ "$in_owned" == true ]]; then
        echo -e "${RED}Error: Nushell config contains an unterminated Nurl sentinel block: $source${NC}" >&2
        return 1
    fi

    if [[ "$removed" != true ]]; then
        return
    fi
    CLEAN_CONFIG_CHANGED=true
    : > "$destination"
    if (( ${#output[@]} == 0 )); then
        return
    fi
    local last=$(( ${#output[@]} - 1 ))
    for ((index = 0; index <= last; index++)); do
        printf '%s' "${output[$index]}" >> "$destination"
        if (( index < last )) || [[ "$trailing_newline" == true ]]; then
            printf '\n' >> "$destination"
        fi
    done
}

cleanup_on_failure() {
    local status=$?
    if [[ "$status" -ne 0 && "$BACKUP_COMPLETE" != true && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR"
    fi
    if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
        rm -rf "$WORK_ROOT"
    fi
    exit "$status"
}
trap cleanup_on_failure EXIT

echo -e "${BLUE}Uninstalling Nurl${NC}"
echo

if [[ -L "$NURL_HOME" ]]; then
    echo -e "${RED}Error: Refusing to uninstall through a symlinked Nurl root: $NURL_HOME${NC}" >&2
    exit 1
fi
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
    elif exec 3<>/dev/tty 2>/dev/null; then
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

CONFIG_PATHS=("$RESOLVED_CONFIG_DIR/config.nu")
if [[ "$LEGACY_CONFIG_DIR/config.nu" != "${CONFIG_PATHS[0]}" ]]; then
    CONFIG_PATHS+=("$LEGACY_CONFIG_DIR/config.nu")
fi

WORK_ROOT="$(mktemp -d "$HOME/.nurl-uninstall.XXXXXX")"
CONFIG_SOURCES=()
CONFIG_CANDIDATES=()
for config_path in "${CONFIG_PATHS[@]}"; do
    if [[ -L "$config_path" || ( -e "$config_path" && ! -f "$config_path" ) ]]; then
        echo -e "${RED}Error: Refusing to replace a non-file Nushell config: $config_path${NC}" >&2
        exit 1
    fi
    if [[ -f "$config_path" ]]; then
        candidate="$WORK_ROOT/config-${#CONFIG_CANDIDATES[@]}.nu"
        prepare_clean_config "$config_path" "$candidate"
        if [[ "$CLEAN_CONFIG_CHANGED" == true ]]; then
            CONFIG_SOURCES+=("$config_path")
            CONFIG_CANDIDATES+=("$candidate")
        fi
    fi
done

BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$(mktemp -d "$HOME/.nurl-backup-$BACKUP_STAMP.XXXXXX")"
echo "[1/3] Creating a complete backup..."
cp -pR "$NURL_HOME"/. "$BACKUP_DIR"/
if ! diff -qr "$NURL_HOME" "$BACKUP_DIR" >/dev/null; then
    echo -e "${RED}Error: Backup verification failed; Nurl was not removed.${NC}" >&2
    exit 1
fi
BACKUP_COMPLETE=true

echo "[2/3] Removing $NURL_HOME..."
rm -rf "$NURL_HOME"
if [[ -e "$NURL_HOME" || -L "$NURL_HOME" ]]; then
    echo -e "${RED}Error: Nurl could not be completely removed. The verified backup remains at $BACKUP_DIR.${NC}" >&2
    exit 1
fi

echo "[3/3] Cleaning owned Nushell config entries..."
for ((index = 0; index < ${#CONFIG_SOURCES[@]}; index++)); do
    config_path="${CONFIG_SOURCES[$index]}"
    config_dir="$(dirname "$config_path")"
    config_temp="$(mktemp "$config_dir/.config.nu.nurl.XXXXXX")"
    cp "${CONFIG_CANDIDATES[$index]}" "$config_temp"
    mv -f "$config_temp" "$config_path"
done

echo
echo -e "${GREEN}Nurl uninstalled${NC}"
echo
echo "A complete, byte-verified backup was copied to:"
echo -e "  ${BLUE}$BACKUP_DIR${NC}"
echo "The backup includes all files that were present under $NURL_HOME,"
echo "including collections, chains, history, and NUON configuration."
