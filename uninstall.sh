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
    local displaced
    LAST_CONFIG_BACKUP=''
    probe_mv_no_clobber "$(dirname "$destination")" || return 1
    displaced="$(mktemp "$(dirname "$destination")/.config.nu.nurl.rollback.XXXXXX")"
    rm -f "$displaced"
    CONFIG_DISPLACED="$displaced"
    CONFIG_DISPLACED_DEST="$destination"
    mv "$destination" "$displaced"
    if ! cmp -s "$snapshot" "$displaced"; then
        if ! restore_displaced_config "$displaced" "$destination"; then
            echo "Error: config recovery remains at $displaced." >&2
        fi
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
        echo "Error: Nushell config changed during uninstall; the concurrent edit was preserved. The Nurl backup remains at $BACKUP_DIR." >&2
        return 1
    fi
    if ! mv -n "$source" "$destination" || [[ -e "$source" ]]; then
        if ! restore_displaced_config "$displaced" "$destination"; then
            echo "Error: config recovery remains at $displaced." >&2
        fi
        CONFIG_DISPLACED=''
        CONFIG_DISPLACED_DEST=''
        echo "Error: Nushell config could not be updated. The Nurl backup remains at $BACKUP_DIR." >&2
        return 1
    fi
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

validate_config_bytes() {
    local source="$1"
    local display_path="$2"
    local scratch_root="${WORK_ROOT:-$HOME}"
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

prepare_clean_config() {
    local source="$1"
    local destination="$2"
    local display_path="$3"
    CLEAN_CONFIG_CHANGED=false
    validate_config_bytes "$source" "$display_path"
    if transform_config_file uninstall "$source" "$destination" "$display_path"; then
        CLEAN_CONFIG_CHANGED=true
    else
        local status=$?
        if [[ "$status" -eq 3 ]]; then CLEAN_CONFIG_CHANGED=false; else return "$status"; fi
    fi
}

cleanup_on_failure() {
    local status=$?
    local index
    if [[ -n "$CONFIG_DISPLACED" && -e "$CONFIG_DISPLACED" ]]; then
        if ! restore_displaced_config "$CONFIG_DISPLACED" "$CONFIG_DISPLACED_DEST"; then
            echo "Error: interrupted config recovery remains at $CONFIG_DISPLACED." >&2
        fi
    fi
    for ((index = ${#CONFIG_REPLACEMENT_PATHS[@]} - 1; index >= 0; index--)); do
        if [[ -e "${CONFIG_REPLACEMENT_BACKUPS[$index]}" ]] &&
           [[ -f "${CONFIG_REPLACEMENT_PATHS[$index]}" ]] &&
           cmp -s "${CONFIG_REPLACEMENT_CANDIDATES[$index]}" "${CONFIG_REPLACEMENT_PATHS[$index]}"; then
            rm -f "${CONFIG_REPLACEMENT_PATHS[$index]}"
            if ! restore_displaced_config "${CONFIG_REPLACEMENT_BACKUPS[$index]}" "${CONFIG_REPLACEMENT_PATHS[$index]}"; then
                echo "Error: config recovery remains at ${CONFIG_REPLACEMENT_BACKUPS[$index]}." >&2
            fi
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

for required_tool in od awk perl wc sed tr uname find dirname basename mktemp cp mv rm chmod cmp stat readlink rmdir date tar cksum; do
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
    if [[ -L "$config_path" || ! -f "$config_path" ]]; then
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
    prepare_clean_config "$original" "$candidate" "$config_path"
    if [[ "$CLEAN_CONFIG_CHANGED" == true ]]; then
        if [[ ! -w "$(dirname "$config_path")" ]]; then
            echo -e "${RED}Error: Nushell config contains Nurl entries but is not writable: $config_path${NC}" >&2
            exit 1
        fi
        probe_mv_no_clobber "$(dirname "$config_path")" || exit 1
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
echo "A complete, byte-verified backup was moved to:"
echo -e "  ${BLUE}$BACKUP_DIR${NC}"
echo "The backup includes all files that were present under $NURL_HOME,"
echo "including collections, chains, history, and NUON configuration."
