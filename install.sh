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
REPO_URL="${NURL_REPO_URL:-https://raw.githubusercontent.com/chand45/Nurl/main}"
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
BACKUP_DESTS=()
BACKUP_PATHS=()
CREATED_PATHS=()
CREATED_DIRS=()

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

    local bodies=()
    local line clean
    while IFS= read -r line || [[ -n "$line" ]]; do
        bodies+=("$line")
    done < "$source"

    local trailing_newline=false
    if [[ -s "$source" ]] && [[ "$(tail -c 1 "$source" | od -An -t u1 | tr -d '[:space:]')" == '10' ]]; then
        trailing_newline=true
    fi

    local owned_start=-1
    local owned_end=-1
    local in_owned=false
    local index
    for ((index = 0; index < ${#bodies[@]}; index++)); do
        clean="${bodies[$index]%$'\r'}"
        clean="$(trim_ascii_space "$clean")"
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

    local use_cr=false
    for line in "${bodies[@]}"; do
        if [[ "$line" == *$'\r' ]]; then
            use_cr=true
            break
        fi
    done
    local suffix=''
    if [[ "$use_cr" == true ]]; then
        suffix=$'\r'
    fi

    local output=()
    local inserted=false
    for line in "${bodies[@]}"; do
        if is_legacy_source_line "$line"; then
            if [[ "$inserted" != true ]]; then
                local output_count=${#output[@]}
                if (( output_count > 0 )) && is_legacy_comment_line "${output[$((output_count - 1))]}"; then
                    unset 'output[output_count-1]'
                    output=("${output[@]}")
                fi
                local final_suffix="$suffix"
                if [[ "$trailing_newline" != true ]]; then
                    final_suffix=''
                fi
                output+=("# >>> nurl >>>${suffix}" "source ~/.nurl/api.nu${suffix}" "# <<< nurl <<<${final_suffix}")
                inserted=true
            fi
            continue
        fi
        output+=("$line")
    done

    if [[ "$inserted" != true ]]; then
        local output_count=${#output[@]}
        if [[ "$use_cr" == true && "$output_count" -gt 0 && "${output[$((output_count - 1))]}" != *$'\r' ]]; then
            output[$((output_count - 1))]+=$'\r'
        fi
        local final_suffix="$suffix"
        if [[ "$trailing_newline" != true ]]; then
            final_suffix=''
        fi
        output+=("# >>> nurl >>>${suffix}" "source ~/.nurl/api.nu${suffix}" "# <<< nurl <<<${final_suffix}")
    fi

    : > "$destination"
    local last=$(( ${#output[@]} - 1 ))
    for ((index = 0; index <= last; index++)); do
        printf '%s' "${output[$index]}" >> "$destination"
        if (( index < last )) || [[ "$trailing_newline" == true ]] || [[ ! -s "$source" ]]; then
            printf '\n' >> "$destination"
        fi
    done
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
    else
        CREATED_PATHS+=("$destination")
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
    local index
    for ((index = ${#CREATED_PATHS[@]} - 1; index >= 0; index--)); do
        rm -rf "${CREATED_PATHS[$index]}"
    done
    for ((index = ${#BACKUP_DESTS[@]} - 1; index >= 0; index--)); do
        rm -rf "${BACKUP_DESTS[$index]}"
        mv -f "${BACKUP_PATHS[$index]}" "${BACKUP_DESTS[$index]}"
    done
    if [[ "$FRESH_PROMOTED" == true ]]; then
        rm -rf "$NURL_HOME"
    fi
    for ((index = ${#CREATED_DIRS[@]} - 1; index >= 0; index--)); do
        rmdir "${CREATED_DIRS[$index]}" 2>/dev/null || true
    done
}

finish() {
    local status=$?
    if [[ "$status" -ne 0 && "$PROMOTION_STARTED" == true && "$COMMITTED" != true ]]; then
        rollback_install
    fi
    if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
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
NUSHELL_CONFIG="$NUSHELL_CONFIG_DIR/config.nu"
CONFIG_BOUNDARY='/'
case "$NUSHELL_CONFIG_DIR" in
    "$HOME"|"$HOME"/*)
        CONFIG_BOUNDARY="$HOME"
        ;;
esac
for install_directory in \
    "$NURL_HOME" \
    "$NURL_HOME/nu_modules" \
    "$NURL_HOME/collections" \
    "$NURL_HOME/chains" \
    "$NURL_HOME/history"; do
    assert_safe_directory_chain "$install_directory" "$HOME"
done
assert_safe_directory_chain "$NUSHELL_CONFIG_DIR" "$CONFIG_BOUNDARY"
if [[ -L "$NUSHELL_CONFIG" || ( -e "$NUSHELL_CONFIG" && ! -f "$NUSHELL_CONFIG" ) ]]; then
    echo -e "${RED}Error: Refusing to replace non-file Nushell config path: $NUSHELL_CONFIG${NC}" >&2
    exit 1
fi

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
prepare_config_candidate "$NUSHELL_CONFIG" "$CONFIG_CANDIDATE"

echo "[3/4] Promoting validated payloads..."
PROMOTION_STARTED=true
if [[ "$IS_UPDATE" != true ]]; then
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
    remember_created_dir "$NUSHELL_CONFIG_DIR"
    CONFIG_TEMP="$(mktemp "$NUSHELL_CONFIG_DIR/.config.nu.nurl.XXXXXX")"
    cp "$CONFIG_CANDIDATE" "$CONFIG_TEMP"
    promote_file "$CONFIG_TEMP" "$NUSHELL_CONFIG" "nushell-config.nu"
    echo "  Added the owned Nurl block to $NUSHELL_CONFIG"
else
    echo "  Nushell config already contains the owned Nurl block"
fi

COMMITTED=true
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
