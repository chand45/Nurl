#!/bin/bash
# Nurl Installation Script for Linux/macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/chand45/Nurl/main/install.sh | bash

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
REPO_URL="https://raw.githubusercontent.com/chand45/Nurl/main"
MINIMUM_CURL_VERSION="7.75.0"
MINIMUM_NUSHELL_VERSION="0.89.0"
MODULES=("mod.nu" "http.nu" "auth.nu" "vars.nu" "history.nu" "chain.nu" "tui.nu" "log.nu" "resource-path.nu" "command-error.nu" "curl-capability.nu" "string-compat.nu")
ENVS=("default.nuon" "dev.nuon" "staging.nuon")
REQUESTS=("create-post.nuon" "delete-post.nuon" "get-comments.nuon" "get-post.nuon" "get-posts.nuon" "get-users.nuon" "update-post.nuon")

STAGE_ROOT=''
ROLLBACK_DIR=''
PROMOTION_STARTED=false
COMMITTED=false
FRESH_PROMOTED=false
FRESH_SIGNATURE=''
BACKUP_DESTS=()
BACKUP_PATHS=()
BACKUP_CANDIDATES=()
CREATED_PATHS=()
CREATED_CANDIDATES=()
CREATED_DIRS=()
CONFIG_TEMP=''
CONFIG_DISPLACED=''
CONFIG_DISPLACED_DEST=''
ROLLBACK_FAILED=false

version_at_least() {
    local actual_major="$1"
    local actual_minor="$2"
    local actual_patch="$3"
    local minimum="$4"
    local minimum_major minimum_minor minimum_patch
    IFS=. read -r minimum_major minimum_minor minimum_patch <<< "$minimum"
    (( actual_major > minimum_major ||
       (actual_major == minimum_major && actual_minor > minimum_minor) ||
       (actual_major == minimum_major && actual_minor == minimum_minor && actual_patch >= minimum_patch) ))
}

parse_version_line() {
    local line="$1"
    if [[ ! "$line" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([^0-9.].*)?$ ]]; then
        return 1
    fi
    PARSED_MAJOR="${BASH_REMATCH[1]}"
    PARSED_MINOR="${BASH_REMATCH[2]}"
    PARSED_PATCH="${BASH_REMATCH[3]}"
}

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
    local original_exists="$4"
    local parent displaced
    LAST_CONFIG_BACKUP=''

    if [[ -e "$destination" || -L "$destination" ]]; then
        displaced="$(mktemp "$(dirname "$destination")/.config.nu.nurl.rollback.XXXXXX")"
        rm -f "$displaced"
        CONFIG_DISPLACED="$displaced"
        CONFIG_DISPLACED_DEST="$destination"
        mv "$destination" "$displaced"
        if [[ "$original_exists" != true ]] || ! cmp -s "$snapshot" "$displaced"; then
            if ! restore_displaced_config "$displaced" "$destination"; then
                echo "Error: Nushell config changed and recovery remains at $displaced." >&2
                ROLLBACK_FAILED=true
            fi
            CONFIG_DISPLACED=''
            CONFIG_DISPLACED_DEST=''
            echo "Error: Nushell config changed during installation; the concurrent edit was preserved." >&2
            return 1
        fi
        if ! ln "$source" "$destination"; then
            restore_displaced_config "$displaced" "$destination" || {
                echo "Error: Nushell config recovery remains at $displaced." >&2
                ROLLBACK_FAILED=true
            }
            CONFIG_DISPLACED=''
            CONFIG_DISPLACED_DEST=''
            return 1
        fi
        rm -f "$source"
        LAST_CONFIG_BACKUP="$displaced"
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
    else
        if [[ "$original_exists" == true ]]; then
            echo "Error: Nushell config disappeared during installation; no config changes were applied." >&2
            return 1
        fi
        ln "$source" "$destination"
        rm -f "$source"
    fi
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
    local char='' line byte
    local pending_cr=false
    local CR=$'\r'
    local LF=$'\n'
    CONFIG_BODIES=()
    CONFIG_EOLS=()
    while IFS= read -r line; do
        for byte in $line; do
            if [[ "$byte" == '0' ]]; then
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
                printf -v char "\\$(printf '%03o' "$byte")"
                body+="$char"
            fi
        done
    done < <(od -An -v -tu1 "$source")
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

assert_safe_directory_chain() {
    local directory="$1"
    local boundary="$2"
    local current="$directory"
    local parent
    while [[ "$current" != "$boundary" && "$current" != '/' && "$current" != '.' ]]; do
        if [[ -L "$current" ]]; then
            echo -e "${RED}Error: Refusing to install through a symlinked directory: $current${NC}" >&2
            return 1
        fi
        if [[ -e "$current" && ! -d "$current" ]]; then
            echo -e "${RED}Error: Expected an install directory but found another item: $current${NC}" >&2
            return 1
        fi
        parent="$(dirname "$current")"
        if [[ "$parent" == "$current" ]]; then
            break
        fi
        current="$parent"
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

prepare_config_candidate() {
    local source="$1"
    local destination="$2"
    CONFIG_CHANGED=true

    if [[ ! -f "$source" ]]; then
        printf '%s\n%s\n%s\n' \
            '# >>> nurl >>>' \
            'source ~/.nurl/api.nu' \
            '# <<< nurl <<<' > "$destination"
        return
    fi

    read_config_records "$source"
    local preferred_eol=$'\n'
    local eol
    for eol in "${CONFIG_EOLS[@]}"; do
        if [[ -n "$eol" ]]; then
            preferred_eol="$eol"
            break
        fi
    done
    local trailing_newline=false
    if (( ${#CONFIG_EOLS[@]} > 0 )) && [[ -n "${CONFIG_EOLS[$(( ${#CONFIG_EOLS[@]} - 1 ))]}" ]]; then
        trailing_newline=true
    fi

    local owned_start=-1
    local owned_end=-1
    local in_owned=false
    local index
    for ((index = 0; index < ${#CONFIG_BODIES[@]}; index++)); do
        clean="$(trim_ascii_space "${CONFIG_BODIES[$index]}")"
        if [[ "$clean" == '# >>> nurl >>>' ]]; then
            if [[ "$in_owned" == true || "$owned_start" -ge 0 ]]; then
                echo -e "${RED}Error: Nushell config contains an invalid Nurl sentinel block.${NC}" >&2
                return 1
            fi
            in_owned=true
            owned_start=$index
        elif [[ "$clean" == '# <<< nurl <<<' ]]; then
            if [[ "$in_owned" != true ]]; then
                echo -e "${RED}Error: Nushell config contains an invalid Nurl sentinel block.${NC}" >&2
                return 1
            fi
            in_owned=false
            owned_end=$index
        fi
    done
    if [[ "$in_owned" == true ]]; then
        echo -e "${RED}Error: Nushell config contains an unterminated Nurl sentinel block.${NC}" >&2
        return 1
    fi
    if [[ "$owned_start" -ge 0 && "$owned_end" -ge "$owned_start" ]]; then
        CONFIG_CHANGED=false
        return
    fi

    local output_bodies=()
    local output_eols=()
    local inserted=false
    local line
    for ((index = 0; index < ${#CONFIG_BODIES[@]}; index++)); do
        line="${CONFIG_BODIES[$index]}"
        if is_legacy_source_line "$line"; then
            if [[ "$inserted" != true ]]; then
                local output_count=${#output_bodies[@]}
                if (( output_count > 0 )) && is_legacy_comment_line "${output_bodies[$((output_count - 1))]}"; then
                    unset 'output_bodies[output_count-1]'
                    unset 'output_eols[output_count-1]'
                    output_bodies=("${output_bodies[@]}")
                    output_eols=("${output_eols[@]}")
                fi
                output_bodies+=("# >>> nurl >>>" "source ~/.nurl/api.nu" "# <<< nurl <<<")
                output_eols+=("$preferred_eol" "$preferred_eol" "${CONFIG_EOLS[$index]}")
                inserted=true
            fi
            continue
        fi
        output_bodies+=("$line")
        output_eols+=("${CONFIG_EOLS[$index]}")
    done

    if [[ "$inserted" != true ]]; then
        local output_count=${#output_bodies[@]}
        if (( output_count > 0 )) && [[ -z "${output_eols[$((output_count - 1))]}" ]]; then
            output_eols[$((output_count - 1))]="$preferred_eol"
        fi
        local final_eol=''
        if [[ "$trailing_newline" == true || "$output_count" -eq 0 ]]; then
            final_eol="$preferred_eol"
        fi
        output_bodies+=("# >>> nurl >>>" "source ~/.nurl/api.nu" "# <<< nurl <<<")
        output_eols+=("$preferred_eol" "$preferred_eol" "$final_eol")
    fi

    write_config_records "$destination"
}

remember_created_dir() {
    local directory="$1"
    if [[ ! -d "$directory" ]]; then
        local missing=()
        local current="$directory"
        local parent
        while [[ ! -d "$current" ]]; do
            missing+=("$current")
            parent="$(dirname "$current")"
            if [[ "$parent" == "$current" ]]; then
                break
            fi
            current="$parent"
        done
        mkdir -p "$directory"
        local index
        for ((index = ${#missing[@]} - 1; index >= 0; index--)); do
            CREATED_DIRS+=("${missing[$index]}")
        done
    fi
}

promote_file() {
    local source="$1"
    local destination="$2"
    local backup_name="$3"
    local parent
    parent="$(dirname "$destination")"
    remember_created_dir "$parent"
    if [[ -L "$destination" || ( -e "$destination" && ! -f "$destination" ) ]]; then
        echo -e "${RED}Error: Refusing to replace non-file install path: $destination${NC}" >&2
        return 1
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        local backup="$ROLLBACK_DIR/$backup_name"
        mkdir -p "$(dirname "$backup")"
        cp -pP "$destination" "$backup"
        BACKUP_DESTS+=("$destination")
        BACKUP_PATHS+=("$backup")
        BACKUP_CANDIDATES+=('')
    else
        CREATED_PATHS+=("$destination")
        CREATED_CANDIDATES+=('')
    fi
    mv -f "$source" "$destination"
}

promote_if_absent() {
    local source="$1"
    local destination="$2"
    local backup_name="$3"
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        promote_file "$source" "$destination" "$backup_name"
    fi
}

rollback_install() {
    set +e
    ROLLBACK_FAILED=false
    local index
    for ((index = ${#CREATED_PATHS[@]} - 1; index >= 0; index--)); do
        if [[ -n "${CREATED_CANDIDATES[$index]}" ]]; then
            echo "Warning: rollback preserved the live created config to avoid deleting concurrent data." >&2
            ROLLBACK_FAILED=true
            continue
        fi
        if ! rm -rf "${CREATED_PATHS[$index]}"; then
            echo "Warning: rollback could not remove '${CREATED_PATHS[$index]}'." >&2
            ROLLBACK_FAILED=true
        fi
    done
    for ((index = ${#BACKUP_DESTS[@]} - 1; index >= 0; index--)); do
        if [[ -n "${BACKUP_CANDIDATES[$index]}" ]]; then
            echo "Warning: rollback preserved the live config; recovery remains at '${BACKUP_PATHS[$index]}'." >&2
            ROLLBACK_FAILED=true
            continue
        fi
        if ! rm -rf "${BACKUP_DESTS[$index]}" ||
           ! mv -f "${BACKUP_PATHS[$index]}" "${BACKUP_DESTS[$index]}"; then
            echo "Warning: rollback could not restore '${BACKUP_DESTS[$index]}'." >&2
            ROLLBACK_FAILED=true
        fi
    done
    if [[ "$FRESH_PROMOTED" == true ]]; then
        echo "Warning: rollback preserved the visible fresh installation to avoid deleting concurrent data." >&2
        ROLLBACK_FAILED=true
    fi
    for ((index = ${#CREATED_DIRS[@]} - 1; index >= 0; index--)); do
        rmdir "${CREATED_DIRS[$index]}" 2>/dev/null || true
    done
}

finish() {
    local status=$?
    if [[ -n "$CONFIG_TEMP" && -e "$CONFIG_TEMP" ]]; then
        rm -f "$CONFIG_TEMP" || true
    fi
    if [[ -n "$CONFIG_DISPLACED" && -e "$CONFIG_DISPLACED" ]]; then
        if ! restore_displaced_config "$CONFIG_DISPLACED" "$CONFIG_DISPLACED_DEST"; then
            echo "Error: interrupted config recovery remains at $CONFIG_DISPLACED." >&2
            ROLLBACK_FAILED=true
        fi
    fi
    if [[ "$status" -ne 0 && "$PROMOTION_STARTED" == true && "$COMMITTED" != true ]]; then
        rollback_install
    fi
    if [[ "$ROLLBACK_FAILED" == true ]]; then
        echo "Error: rollback was incomplete; recovery files remain at $ROLLBACK_DIR." >&2
    elif [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
        rm -rf "$STAGE_ROOT"
    fi
    exit "$status"
}
trap finish EXIT

echo -e "${BLUE}Installing Nurl - Terminal API Client${NC}"
echo

if ! command -v nu >/dev/null 2>&1; then
    echo -e "${RED}Error: Nushell is not installed.${NC}" >&2
    echo "Please install Nushell first: https://www.nushell.sh/book/installation.html" >&2
    exit 1
fi

if ! NUSHELL_VERSION_OUTPUT="$(nu --version 2>/dev/null)"; then
    echo -e "${RED}Error: Could not determine the installed Nushell version.${NC}" >&2
    exit 1
fi
NUSHELL_VERSION_LINE="${NUSHELL_VERSION_OUTPUT%%$'\n'*}"
NUSHELL_VERSION_LINE="${NUSHELL_VERSION_LINE%$'\r'}"
if ! parse_version_line "$NUSHELL_VERSION_LINE"; then
    echo -e "${RED}Error: Could not determine the installed Nushell version.${NC}" >&2
    exit 1
fi
NUSHELL_VERSION="$PARSED_MAJOR.$PARSED_MINOR.$PARSED_PATCH"
if ! version_at_least "$PARSED_MAJOR" "$PARSED_MINOR" "$PARSED_PATCH" "$MINIMUM_NUSHELL_VERSION"; then
    echo -e "${RED}Error: Nushell $MINIMUM_NUSHELL_VERSION or newer is required (found $NUSHELL_VERSION).${NC}" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl is not installed.${NC}" >&2
    echo "Please install curl first." >&2
    exit 1
fi

if ! CURL_VERSION_OUTPUT="$(curl --version 2>/dev/null)"; then
    echo -e "${RED}Error: Could not determine the installed curl version.${NC}" >&2
    exit 1
fi
CURL_VERSION_LINE="${CURL_VERSION_OUTPUT%%$'\n'*}"
CURL_VERSION_LINE="${CURL_VERSION_LINE%$'\r'}"
if [[ ! "$CURL_VERSION_LINE" =~ ^curl(\.exe)?[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+)([^0-9.].*)?$ ]]; then
    echo -e "${RED}Error: Could not determine the installed curl version.${NC}" >&2
    exit 1
fi
CURL_MAJOR="${BASH_REMATCH[2]}"
CURL_MINOR="${BASH_REMATCH[3]}"
CURL_PATCH="${BASH_REMATCH[4]}"
CURL_VERSION="$CURL_MAJOR.$CURL_MINOR.$CURL_PATCH"
if ! version_at_least "$CURL_MAJOR" "$CURL_MINOR" "$CURL_PATCH" "$MINIMUM_CURL_VERSION"; then
    echo -e "${RED}Error: curl $MINIMUM_CURL_VERSION or newer is required (found $CURL_VERSION).${NC}" >&2
    exit 1
fi

NUSHELL_CONFIG_DIR="$(
    nu --no-config-file -c '$nu.default-config-dir' 2>/dev/null \
        | sed -n '1p' \
        | tr -d '\r'
)" || true
if [[ -z "$NUSHELL_CONFIG_DIR" ]]; then
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        NUSHELL_CONFIG_DIR="$XDG_CONFIG_HOME/nushell"
    elif [[ "$(uname -s 2>/dev/null || true)" == 'Darwin' ]]; then
        NUSHELL_CONFIG_DIR="$HOME/Library/Application Support/nushell"
    else
        NUSHELL_CONFIG_DIR="$HOME/.config/nushell"
    fi
fi
if [[ -L "$NURL_HOME" ]]; then
    echo -e "${RED}Error: Refusing to install through a symlinked Nurl root: $NURL_HOME${NC}" >&2
    exit 1
fi
NURL_HOME="$(canonicalize_directory_path "$NURL_HOME")" || {
    echo -e "${RED}Error: Could not resolve Nurl installation path: $NURL_HOME${NC}" >&2
    exit 1
}
HOME_BOUNDARY="$(canonicalize_directory_path "$HOME")" || {
    echo -e "${RED}Error: Could not resolve the home directory: $HOME${NC}" >&2
    exit 1
}
for install_directory in \
    "$NURL_HOME" \
    "$NURL_HOME/nu_modules" \
    "$NURL_HOME/collections" \
    "$NURL_HOME/chains" \
    "$NURL_HOME/history"; do
    assert_safe_directory_chain "$install_directory" "$HOME_BOUNDARY"
done
NUSHELL_CONFIG_DIR="$(canonicalize_directory_path "$NUSHELL_CONFIG_DIR")" || {
    echo -e "${RED}Error: Refusing to use a non-directory Nushell config path: $NUSHELL_CONFIG_DIR${NC}" >&2
    exit 1
}
NUSHELL_CONFIG="$NUSHELL_CONFIG_DIR/config.nu"
if [[ -L "$NUSHELL_CONFIG" ]]; then
    RESOLVED_CONFIG_FILE="$(resolve_config_path "$NUSHELL_CONFIG")" || {
        echo -e "${RED}Error: Nushell config link could not be resolved safely: $NUSHELL_CONFIG${NC}" >&2
        exit 1
    }
    if [[ ! -f "$RESOLVED_CONFIG_FILE" || ! -w "$RESOLVED_CONFIG_FILE" ]]; then
        echo -e "${RED}Error: Nushell config link does not resolve to a writable file: $NUSHELL_CONFIG${NC}" >&2
        exit 1
    fi
    NUSHELL_CONFIG="$RESOLVED_CONFIG_FILE"
elif [[ -e "$NUSHELL_CONFIG" && ! -f "$NUSHELL_CONFIG" ]]; then
    echo -e "${RED}Error: Refusing to replace non-file Nushell config path: $NUSHELL_CONFIG${NC}" >&2
    exit 1
fi
CONFIG_TARGET_DIR="$(dirname "$NUSHELL_CONFIG")"
CONFIG_WRITABLE_PARENT="$CONFIG_TARGET_DIR"
while [[ ! -e "$CONFIG_WRITABLE_PARENT" ]]; do
    CONFIG_WRITABLE_PARENT="$(dirname "$CONFIG_WRITABLE_PARENT")"
done
if [[ ! -d "$CONFIG_WRITABLE_PARENT" || ! -w "$CONFIG_WRITABLE_PARENT" ]]; then
    echo -e "${RED}Error: Nushell config target directory is not writable: $CONFIG_TARGET_DIR${NC}" >&2
    exit 1
fi
case "$NUSHELL_CONFIG_DIR/" in
    "$NURL_HOME/"*)
        echo -e "${RED}Error: Nushell config directory must not resolve inside $NURL_HOME.${NC}" >&2
        exit 1
        ;;
esac
case "$NUSHELL_CONFIG" in
    "$NURL_HOME"|"$NURL_HOME"/*)
        echo -e "${RED}Error: Nushell config file must not resolve inside $NURL_HOME.${NC}" >&2
        exit 1
        ;;
esac

IS_UPDATE=false
if [[ -d "$NURL_HOME" ]]; then
    IS_UPDATE=true
    echo -e "${YELLOW}Existing installation detected. Updating...${NC}"
fi

STAGE_ROOT="$(mktemp -d "$HOME/.nurl-stage.XXXXXX")"
PAYLOAD_ROOT="$STAGE_ROOT/install"
ROLLBACK_DIR="$STAGE_ROOT/rollback"
mkdir -p "$PAYLOAD_ROOT/nu_modules" "$ROLLBACK_DIR"

echo "[1/4] Staging Nurl payloads..."
curl -fsSL "$REPO_URL/api.nu" -o "$PAYLOAD_ROOT/api.nu"
for module in "${MODULES[@]}"; do
    curl -fsSL "$REPO_URL/nu_modules/$module" -o "$PAYLOAD_ROOT/nu_modules/$module"
done

mkdir -p "$PAYLOAD_ROOT/collections" "$PAYLOAD_ROOT/chains" "$PAYLOAD_ROOT/history"
if [[ ! -d "$NURL_HOME/collections/jsonplaceholder" ]]; then
    echo "  Staging example collection: jsonplaceholder"
    mkdir -p "$PAYLOAD_ROOT/collections/jsonplaceholder/environments" "$PAYLOAD_ROOT/collections/jsonplaceholder/requests"
    curl -fsSL "$REPO_URL/collections/jsonplaceholder/collection.nuon" -o "$PAYLOAD_ROOT/collections/jsonplaceholder/collection.nuon"
    curl -fsSL "$REPO_URL/collections/jsonplaceholder/meta.nuon" -o "$PAYLOAD_ROOT/collections/jsonplaceholder/meta.nuon"
    for environment in "${ENVS[@]}"; do
        curl -fsSL "$REPO_URL/collections/jsonplaceholder/environments/$environment" -o "$PAYLOAD_ROOT/collections/jsonplaceholder/environments/$environment"
    done
    for request in "${REQUESTS[@]}"; do
        curl -fsSL "$REPO_URL/collections/jsonplaceholder/requests/$request" -o "$PAYLOAD_ROOT/collections/jsonplaceholder/requests/$request"
    done
fi
if [[ ! -f "$NURL_HOME/chains/example-workflow.nuon" ]]; then
    echo "  Staging example chain: example-workflow"
    curl -fsSL "$REPO_URL/chains/example-workflow.nuon" -o "$PAYLOAD_ROOT/chains/example-workflow.nuon"
fi

cat > "$PAYLOAD_ROOT/config.nuon" <<'EOF'
{
    default_headers: {
        "Content-Type": "application/json"
        "Accept": "application/json"
    }
    timeout_seconds: 30
    history_retention_days: 30
    editor: "code"
    colors: {
        success: "green"
        error: "red"
        warning: "yellow"
        info: "blue"
    }
}
EOF
printf '{}\n' > "$PAYLOAD_ROOT/variables.nuon"
cat > "$PAYLOAD_ROOT/secrets.nuon" <<'EOF'
{
    tokens: {}
    saml_tokens: {}
    oauth: {}
    api_keys: {}
    basic_auth: {}
}
EOF

echo "[2/4] Validating staged payloads..."
if ! nu --no-config-file "$PAYLOAD_ROOT/api.nu" >/dev/null 2>&1; then
    echo -e "${RED}Error: Staged Nurl payloads failed Nushell validation; the existing installation was not changed.${NC}" >&2
    exit 1
fi

CONFIG_CANDIDATE="$STAGE_ROOT/config.nu"
CONFIG_ORIGINAL="$STAGE_ROOT/config.original"
CONFIG_ORIGINAL_EXISTS=false
CONFIG_MODE=''
if [[ -f "$NUSHELL_CONFIG" ]]; then
    cp -p "$NUSHELL_CONFIG" "$CONFIG_ORIGINAL"
    CONFIG_ORIGINAL_EXISTS=true
    CONFIG_MODE="$(get_file_mode "$NUSHELL_CONFIG")" || {
        echo -e "${RED}Error: Could not determine Nushell config permissions: $NUSHELL_CONFIG${NC}" >&2
        exit 1
    }
fi
prepare_config_candidate "$CONFIG_ORIGINAL" "$CONFIG_CANDIDATE"

echo "[3/4] Promoting validated payloads..."
PROMOTION_STARTED=true
if [[ "$IS_UPDATE" != true ]]; then
    FRESH_SIGNATURE="$(cd "$PAYLOAD_ROOT" && tar -cf - . | cksum)"
    mv "$PAYLOAD_ROOT" "$NURL_HOME"
    FRESH_PROMOTED=true
else
    remember_created_dir "$NURL_HOME"
    remember_created_dir "$NURL_HOME/nu_modules"
    promote_file "$PAYLOAD_ROOT/api.nu" "$NURL_HOME/api.nu" "api.nu"
    for module in "${MODULES[@]}"; do
        promote_file "$PAYLOAD_ROOT/nu_modules/$module" "$NURL_HOME/nu_modules/$module" "nu_modules/$module"
    done
    remember_created_dir "$NURL_HOME/collections"
    remember_created_dir "$NURL_HOME/chains"
    remember_created_dir "$NURL_HOME/history"
    promote_if_absent "$PAYLOAD_ROOT/config.nuon" "$NURL_HOME/config.nuon" "config.nuon"
    promote_if_absent "$PAYLOAD_ROOT/variables.nuon" "$NURL_HOME/variables.nuon" "variables.nuon"
    promote_if_absent "$PAYLOAD_ROOT/secrets.nuon" "$NURL_HOME/secrets.nuon" "secrets.nuon"
    if [[ -d "$PAYLOAD_ROOT/collections/jsonplaceholder" && ! -e "$NURL_HOME/collections/jsonplaceholder" && ! -L "$NURL_HOME/collections/jsonplaceholder" ]]; then
        CREATED_PATHS+=("$NURL_HOME/collections/jsonplaceholder")
        mv "$PAYLOAD_ROOT/collections/jsonplaceholder" "$NURL_HOME/collections/jsonplaceholder"
    fi
    if [[ -f "$PAYLOAD_ROOT/chains/example-workflow.nuon" ]]; then
        promote_if_absent "$PAYLOAD_ROOT/chains/example-workflow.nuon" "$NURL_HOME/chains/example-workflow.nuon" "chains/example-workflow.nuon"
    fi
fi

echo "[4/4] Configuring Nushell..."
if [[ "$CONFIG_CHANGED" == true ]]; then
    remember_created_dir "$CONFIG_TARGET_DIR"
    CONFIG_TEMP="$(mktemp "$CONFIG_TARGET_DIR/.config.nu.nurl.XXXXXX")"
    cp "$CONFIG_CANDIDATE" "$CONFIG_TEMP"
    if [[ "$CONFIG_ORIGINAL_EXISTS" == true ]]; then
        chmod "$CONFIG_MODE" "$CONFIG_TEMP"
    fi
    replace_config_safely "$CONFIG_TEMP" "$NUSHELL_CONFIG" "$CONFIG_ORIGINAL" "$CONFIG_ORIGINAL_EXISTS"
    CONFIG_TEMP=''
    if [[ -n "$LAST_CONFIG_BACKUP" ]]; then
        BACKUP_DESTS+=("$NUSHELL_CONFIG")
        BACKUP_PATHS+=("$LAST_CONFIG_BACKUP")
        BACKUP_CANDIDATES+=("$CONFIG_CANDIDATE")
    else
        CREATED_PATHS+=("$NUSHELL_CONFIG")
        CREATED_CANDIDATES+=("$CONFIG_CANDIDATE")
    fi
    echo "  Added the owned Nurl block to $NUSHELL_CONFIG"
else
    echo "  Nushell config already contains the owned Nurl block"
fi

COMMITTED=true
for backup_path in "${BACKUP_PATHS[@]}"; do
    rm -f "$backup_path"
done
rm -rf "$ROLLBACK_DIR"

echo
if [[ "$IS_UPDATE" == true ]]; then
    echo -e "${GREEN}Nurl updated successfully!${NC}"
    echo
    echo "Your data was preserved:"
    echo "  - collections/"
    echo "  - chains/"
    echo "  - secrets.nuon"
    echo "  - history/"
    echo "  - config.nuon"
    echo "  - variables.nuon"
else
    echo -e "${GREEN}Nurl installed successfully!${NC}"
    echo
    echo "Included examples:"
    echo "  - jsonplaceholder collection (7 sample requests)"
    echo "  - example-workflow chain"
fi

echo
echo "Restart your terminal or run:"
echo -e "  ${BLUE}source ~/.nurl/api.nu${NC}"
