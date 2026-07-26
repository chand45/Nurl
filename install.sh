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

probe_mv_no_clobber() {
    local directory="$1"
    local probe_dir source destination move_source move_destination
    probe_dir="$(mktemp -d "$directory/.nurl-mv-probe.XXXXXX")" || return 1
    source="$probe_dir/source"
    destination="$probe_dir/destination"
    printf 'source' > "$source"
    printf 'destination' > "$destination"
    mv -n "$source" "$destination" 2>/dev/null || true
    move_source="$probe_dir/move-source"
    move_destination="$probe_dir/move-destination"
    printf 'move-source' > "$move_source"
    mv -n "$move_source" "$move_destination" 2>/dev/null || true
    if [[ ! -f "$source" || ! -f "$destination" || -e "$move_source" || ! -f "$move_destination" ]]; then
        rm -rf "$probe_dir"
        echo "Error: mv -n is not a safe no-clobber operation in config directory '$directory'." >&2
        return 1
    fi
    rm -rf "$probe_dir"
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
    if mv "$displaced" "$destination" && [[ ! -e "$displaced" && -e "$destination" ]]; then
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
    probe_mv_no_clobber "$(dirname "$destination")" || return 1

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
        if ! mv -n "$source" "$destination" || [[ -e "$source" ]]; then
            restore_displaced_config "$displaced" "$destination" || {
                echo "Error: Nushell config recovery remains at $displaced." >&2
                ROLLBACK_FAILED=true
            }
            CONFIG_DISPLACED=''
            CONFIG_DISPLACED_DEST=''
            return 1
        fi
        LAST_CONFIG_BACKUP="$displaced"
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
    else
        if [[ "$original_exists" == true ]]; then
            echo "Error: Nushell config disappeared during installation; no config changes were applied." >&2
            return 1
        fi
        if ! mv -n "$source" "$destination" || [[ -e "$source" ]]; then
            echo "Error: Nushell config appeared during installation; the candidate was not applied." >&2
            return 1
        fi
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

validate_config_bytes() {
    local source="$1"
    local display_path="$2"
    local scratch_root="${STAGE_ROOT:-$HOME}"
    local byte_stream source_size decoded_count
    byte_stream="$(mktemp "$scratch_root/.nurl-config-bytes.XXXXXX")" || return 1
    if ! od -An -v -tu1 "$source" > "$byte_stream"; then
        rm -f "$byte_stream"
        echo -e "${RED}Error: Could not read Nushell config bytes with od: $display_path${NC}" >&2
        return 1
    fi
    source_size="$(wc -c < "$source")" || { rm -f "$byte_stream"; return 1; }
    decoded_count="$(awk '{count += NF} END {print count + 0}' "$byte_stream")" || { rm -f "$byte_stream"; return 1; }
    rm -f "$byte_stream"
    source_size="${source_size//[[:space:]]/}"
    if [[ "$decoded_count" != "$source_size" ]]; then
        echo -e "${RED}Error: Nushell config byte read was incomplete: expected $source_size bytes, decoded $decoded_count.${NC}" >&2
        return 1
    fi
}

transform_config_file() {
    local mode="$1" source="$2" destination="$3" display_path="$4"
    perl - "$mode" "$source" "$destination" "$display_path" <<'PERL'
use strict;
use warnings;
my ($mode, $source, $destination, $display) = @ARGV;
open my $input, '<:raw', $source or die "Cannot read Nushell config '$source': $!\n";
local $/;
my $data = <$input> // '';
close $input;
die "Nushell config contains an unsupported NUL byte: $display\n" if index($data, "\0") >= 0;
my (@body, @eol);
pos($data) = 0;
while ((pos($data) // 0) < length($data)) {
    my $offset = pos($data) // 0;
    if ($data =~ /\G(.*?)(\r\n|\r|\n)/sg) { push @body, $1; push @eol, $2; }
    else { push @body, substr($data, $offset); push @eol, ''; last; }
}
my $trim = sub { my $v = shift; $v =~ s/^[ \t]+|[ \t]+$//g; return $v; };
my $legacy = sub {
    my $v = $trim->(shift);
    return $v eq 'source ~/.nurl/api.nu' || $v eq 'source "~/.nurl/api.nu"' ||
           $v eq 'source $"($env.HOME)/.nurl/api.nu"';
};
my $legacy_comment = sub { return $trim->(shift) eq '# Nurl - Terminal API Client'; };
my ($inside, $owned) = (0, 0);
for my $line (@body) {
    my $clean = $trim->($line);
    if ($clean eq '# >>> nurl >>>') {
        die "Nushell config contains an invalid Nurl sentinel block: $display\n" if $inside || $owned;
        $inside = 1; $owned = 1;
    } elsif ($clean eq '# <<< nurl <<<') {
        die "Nushell config contains an unmatched Nurl sentinel: $display\n" unless $inside;
        $inside = 0;
    }
}
die "Nushell config contains an unterminated Nurl sentinel block: $display\n" if $inside;
exit 3 if $mode eq 'install' && $owned;
my $preferred = "\n";
for my $ending (@eol) { if (length $ending) { $preferred = $ending; last; } }
my (@out_body, @out_eol);
if ($mode eq 'install') {
    my $inserted = 0;
    for my $index (0 .. $#body) {
        if ($legacy->($body[$index])) {
            if (!$inserted) {
                if (@out_body && $legacy_comment->($out_body[-1])) { pop @out_body; pop @out_eol; }
                push @out_body, '# >>> nurl >>>', 'source ~/.nurl/api.nu', '# <<< nurl <<<';
                push @out_eol, $preferred, $preferred, $eol[$index];
                $inserted = 1;
            }
        } else { push @out_body, $body[$index]; push @out_eol, $eol[$index]; }
    }
    if (!$inserted) {
        $out_eol[-1] = $preferred if @out_body && $out_eol[-1] eq '';
        my $final = (!@body || (@eol && $eol[-1] ne '')) ? $preferred : '';
        push @out_body, '# >>> nurl >>>', 'source ~/.nurl/api.nu', '# <<< nurl <<<';
        push @out_eol, $preferred, $preferred, $final;
    }
} else {
    my ($in_block, $removed) = (0, 0);
    for my $index (0 .. $#body) {
        my $clean = $trim->($body[$index]);
        if ($clean eq '# >>> nurl >>>') { $in_block = 1; $removed = 1; next; }
        if ($clean eq '# <<< nurl <<<') {
            $in_block = 0;
            $out_eol[-1] = '' if $eol[$index] eq '' && $index == $#body && @out_eol;
            next;
        }
        next if $in_block;
        if ($legacy->($body[$index])) {
            if (@out_body && $legacy_comment->($out_body[-1])) { pop @out_body; pop @out_eol; }
            $removed = 1; next;
        }
        push @out_body, $body[$index]; push @out_eol, $eol[$index];
    }
    exit 3 unless $removed;
}
open my $output, '>:raw', $destination or die "Cannot write config candidate '$destination': $!\n";
for my $index (0 .. $#out_body) { print {$output} $out_body[$index], $out_eol[$index]; }
close $output or die "Cannot finish config candidate '$destination': $!\n";
PERL
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

prepare_config_candidate() {
    local source="$1"
    local destination="$2"
    local display_path="$3"
    CONFIG_CHANGED=true
    if [[ ! -f "$source" ]]; then
        printf '%s\n%s\n%s\n' '# >>> nurl >>>' 'source ~/.nurl/api.nu' '# <<< nurl <<<' > "$destination"
        return
    fi
    validate_config_bytes "$source" "$display_path"
    if transform_config_file install "$source" "$destination" "$display_path"; then
        CONFIG_CHANGED=true
    else
        local status=$?
        if [[ "$status" -eq 3 ]]; then CONFIG_CHANGED=false; else return "$status"; fi
    fi
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
    local index
    for ((index = ${#CREATED_PATHS[@]} - 1; index >= 0; index--)); do
        if [[ -n "${CREATED_CANDIDATES[$index]}" ]]; then
            echo "Warning: rollback preserved the live created config to avoid deleting concurrent data." >&2
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
        echo "Inspect '$NURL_HOME'; remove it manually only after preserving any data created there." >&2
    fi
    for ((index = ${#CREATED_DIRS[@]} - 1; index >= 0; index--)); do
        rmdir "${CREATED_DIRS[$index]}" 2>/dev/null || true
    done
}

finish() {
    local status=$?
    set +e
    if [[ -n "$CONFIG_TEMP" && -e "$CONFIG_TEMP" ]]; then
        if ! rm -f "$CONFIG_TEMP"; then
            echo "Warning: could not remove config temp '$CONFIG_TEMP'." >&2
            ROLLBACK_FAILED=true
        fi
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
        if ! rm -rf "$STAGE_ROOT"; then
            echo "Warning: could not remove staging directory '$STAGE_ROOT'." >&2
        fi
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

for required_tool in od awk perl wc sed tr uname dirname basename mktemp cp mv rm chmod cmp stat readlink rmdir; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        echo -e "${RED}Error: $required_tool is required for byte-safe Nushell config editing.${NC}" >&2
        exit 1
    fi
done
set +e
cmp -s /dev/null /dev/null
CMP_PREFLIGHT_STATUS=$?
set -e
if [[ "$CMP_PREFLIGHT_STATUS" -ne 0 ]]; then
    echo -e "${RED}Error: cmp is installed but could not compare files (exit $CMP_PREFLIGHT_STATUS).${NC}" >&2
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
prepare_config_candidate "$CONFIG_ORIGINAL" "$CONFIG_CANDIDATE" "$NUSHELL_CONFIG"

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
        CREATED_CANDIDATES+=('')
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
    set +e
    cmp -s "$CONFIG_CANDIDATE" "$NUSHELL_CONFIG"
    compare_status=$?
    set -e
    if [[ "$compare_status" -ne 0 ]]; then
        if [[ "$compare_status" -eq 1 ]]; then
            echo -e "${RED}Error: Nushell config verification mismatch after promotion.${NC}" >&2
        else
            echo -e "${RED}Error: Could not verify Nushell config after promotion (cmp exit $compare_status).${NC}" >&2
        fi
        exit 1
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
