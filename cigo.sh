#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# cigo — minimal cloud-init wrapper for LXD
#
# CI + GO = cigo. Run cigo and get going.
#
# Author: Petr Palacký <http://palacky.net>
#
# Two separate layers:
#   bootstrap — cloud-config in the template, applied only on first boot
#   pipeline  — "cigo: ..." actions, run on every invocation
#
# Verbs keep the layers apart:
#   create     new container, bootstrap + config + devices + actions
#   redeploy   existing container, config + devices + actions
#   configure  existing container, config + devices only
#   adopt      take over an existing container, config + devices, no bootstrap

set -euo pipefail
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

on_exit() {
    local status=$?
    if [[ -n ${REMOTE_STAGE_DIR:-} && -n ${NAME:-} ]] && command -v lxc >/dev/null 2>&1; then
        if ! lxc exec "$NAME" -- rm -rf -- "$REMOTE_STAGE_DIR" </dev/null >/dev/null 2>&1; then
            warn 'Could not remove temporary staging data from %s: %s\n' "$NAME" "$REMOTE_STAGE_DIR"
        fi
    fi
    if [[ -n ${STAGE_DEVICE:-} && -n ${NAME:-} ]]; then
        lxc config device remove "$NAME" "$STAGE_DEVICE" >/dev/null 2>&1 || true
    fi
    if [[ -n ${TMP_DIR:-} ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    return "$status"
}

setup_colors() {
    UI_COLOR=""; UI_RESET=""
    WARN_COLOR=""; ERR_COLOR=""; ERR_RESET=""
    if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
        UI_COLOR=$'\033[1;36m'; UI_RESET=$'\033[0m'
    fi
    if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
        WARN_COLOR=$'\033[1;33m'
        ERR_COLOR=$'\033[1;31m'; ERR_RESET=$'\033[0m'
    fi
}

setup_colors

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_DIR=""
CIGO_VERSION="0.2.1"
DEFAULT_IMAGE="ubuntu:24.04"
DEFAULT_TIMEOUT=900

# Metadata cigo keeps on the container itself, so no state file is needed.
# LXD reserves the user.* namespace for exactly this purpose.
META_PREFIX="user.cigo."
META_VERSION="user.cigo.version"
META_TEMPLATE="user.cigo.template"
META_CREATED="user.cigo.created-at"
META_ADOPTED="user.cigo.adopted-at"
META_MANAGED="user.cigo.managed-keys"

VERB=""

NAME=""
TEMPLATE=""
IMAGE=""
ASSUME_YES=false
LOG_MODE="journal"
CLOUD_TIMEOUT=$DEFAULT_TIMEOUT
PROFILES=()
CT_CONFIG=()
TEMPLATE_CONFIG=()
TEMPLATE_LABEL=""
ACTIONS=()
DEVICE_NAMES=()
CLI_VARS=()
CLI_IMAGE=""
CLI_FROM=""
CLI_PROFILES=()
CLI_CONFIG=()
CLI_UNSET=()
CLI_REMOVE_DEVICES=()
CLI_SECRET_FILES=()
CLI_SECRET_ENV=()
CLI_TIMEOUT=""
CLI_LOG=""
DRY_RUN=false
CHECK_ONLY=false
DUMP_USER_DATA=""
EXISTING_CT=false
REMOTE_STAGE_DIR=""
# Reporting mode for an existing container: --check and --dry-run compute the
# plan and never mutate LXD state.
PLAN_MODE=false
DRIFT=false
MANAGED_KEYS=()
declare -A VARS=()
declare -A VAR_ORIGIN=()
declare -A INHERIT_CONFIG=()
declare -A DEVICE_TYPES=()
declare -A DEVICE_ARGS=()
INHERIT_KEYS=()
INHERIT_DEVICES=()
PROXY_DEVICES=()
FROM_SOURCE=""
TMP_DIR=""
USER_DATA_FILE=""
STAGE_DEVICE=""
MOUNTPOINT=""

ui() {
    local fmt=$1
    local newline=false
    shift
    case $fmt in
        *$'\n') fmt=${fmt%$'\n'}; newline=true ;;
    esac
    [[ -n $UI_COLOR ]] && printf '%s' "$UI_COLOR"
    printf -- "$fmt" "$@"
    [[ -n $UI_COLOR ]] && printf '%s' "$UI_RESET"
    [[ $newline == true ]] && printf '\n'
    return 0
}

warn() {
    local fmt=$1
    shift
    [[ -n $WARN_COLOR ]] && printf '%s' "$WARN_COLOR" >&2
    printf -- "$fmt" "$@" >&2
    [[ -n $WARN_COLOR ]] && printf '%s' "$ERR_RESET" >&2
    return 0
}

err() {
    local fmt=$1
    shift
    [[ -n $ERR_COLOR ]] && printf '%s' "$ERR_COLOR" >&2
    printf -- "$fmt" "$@" >&2
    [[ -n $ERR_COLOR ]] && printf '%s' "$ERR_RESET" >&2
    return 0
}

fail() {
    err 'Error: %s\n' "$*"
    exit 1
}

# lxc exec forwards stdin to the container, which would consume input meant
# for confirmation prompts. Close stdin here; callers that need it invoke lxc
# exec directly.
ct_exec() {
    lxc exec "$NAME" -- "$@" < /dev/null
}

ct_exec_at() {
    local ct=$1
    shift
    lxc exec "$ct" -- "$@" < /dev/null
}

# Confirmation prompt. The bracketed value is the default, so an empty answer
# takes it: Enter means yes. A closed stdin (no interactive input at all) can
# never be mistaken for consent and always cancels. Use --yes for automation.
confirm() {
    local answer

    if [[ $ASSUME_YES == true ]]; then
        if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
            printf '\033[1;33m%s [Y/n]\033[0m yes (--yes)\n' "$1" >&2
        else
            printf '%s [Y/n] yes (--yes)\n' "$1" >&2
        fi
        return 0
    fi
    if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
        printf '\033[1;33m%s [Y/n]\033[0m ' "$1" >&2
    else
        printf '%s [Y/n] ' "$1" >&2
    fi
    if ! read -r answer; then
        printf '\n' >&2
        return 1
    fi
    answer=${answer:-y}
    case $answer in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'USAGE'
Usage:
  cigo.sh create    --name NAME --template FILE.yaml [options]
  cigo.sh redeploy  --name NAME --template FILE.yaml [options]
  cigo.sh configure --name NAME [--template FILE.yaml] [options]
  cigo.sh adopt     --name NAME --template FILE.yaml [options]
  cigo.sh -V | --version
  cigo.sh -h | --help

Verbs:
  create      Create a new container: config, devices, cloud-init, actions.
  redeploy    Reapply a template to an existing container: config, devices,
              actions. cloud-init is never reapplied.
  configure   Change LXD config and declared devices of an existing container
              only. No actions, no cloud-init.
  adopt       Take over an existing container that cigo did not create:
              config and devices are applied, cloud-init is not.

Options:
  --name NAME               Container name (required)
  --template FILE|DIR       Template file, or a directory with template.yaml
                            (required except for configure)
  --image IMAGE             Image for lxc init (default: ubuntu:24.04, create only)
  --from CONTAINER          Inherit config and devices from a container (create only)
  --profile PROFILE         LXD profile; repeatable, replaces template profiles
  --config KEY=VALUE        Container config; repeatable
  --unset KEY               Remove a config key (configure, redeploy)
  --remove-device NAME      Remove a whole device (configure, redeploy)
  --var NAME=VALUE          Override a template variable; repeatable
  --secret-file NAME=FILE   Secret for cigo: render; relative resolves against $PWD
  --secret-env NAME[=VAR]   Read a render secret from the environment; repeatable
  --timeout SECONDS         Cloud-init timeout (default: 900, create only)
  --log MODE                journal|cloud-init|output|both|none (default: journal)
  --dry-run                 Show the plan without changing LXD state
  --check                   Validate and report drift; changes no LXD state.
                            Exits 1 when an existing container differs.
  --dump-user-data FILE     Write the rendered cloud-config to FILE (create only)
  -y, --yes                 Skip interactive confirmations
  -V, --version             Show the version
  -h, --help                Show this help

Command-line options override matching template directives.

configure without --template is imperative: it applies exactly the given
--config/--unset/--remove-device values, never prunes, and does not touch
cigo metadata. With --template it is declarative and also removes config keys
that cigo wrote earlier but the template no longer declares.

The template is cloud-config. cigo: directives must start at column one and
are removed before the file is passed to cloud-init.

  cigo: image ubuntu:24.04
  cigo: profile default
  cigo: config limits.memory=2GiB
  cigo: device disk web-data source=/srv/www path=/var/www shift=true
  cigo: device proxy web-http listen=tcp:0.0.0.0:8080 connect=tcp:127.0.0.1:80
  cigo: var PHP_VERSION=8.4
  cigo: from source-container
  cigo: packages mc nano
  cigo: copy-host /host/path /path/in/container
  cigo: sync-host /host/path /path/in/container
  cigo: copy-ct other-container /path/in/container
  cigo: sync-ct other-container /path/in/container
  cigo: render host-file.conf.j2 /etc/app.conf [0600]
  cigo: run systemctl restart apache2
  cigo: timeout 900
  cigo: log journal

Actions run in declaration order after cloud-init completes.
A relative copy-host/sync-host/render source resolves against the template
directory, so --template templates/name uses templates/name/files as "files".
cigo: render runs on the host and pushes only the result into the container;
the host needs python3 with jinja2 (python3-jinja2).
Variables use %NAME% and are substituted before upload. Built-ins include
cigo.name, cigo.image, cigo.image_version, cigo.image_codename, cigo.image_os,
cigo.arch, cigo.host, cigo.gateway, cigo.template, and cigo.date.
USAGE
}

# lxc's show subcommands do not accept --format, so structured data comes from
# the stable REST API. Files are normalised to the same {config, devices,
# profiles} shape the jq filters already expect.
lxd_instance_json() {
    lxc query "/1.0/instances/$1"
}

lxd_profile_json() {
    lxc query "/1.0/profiles/$1"
}

# Expanded view: instance-local values merged with its profiles.
lxd_instance_expanded_json() {
    lxd_instance_json "$1" |
        jq '{config: .expanded_config, devices: .expanded_devices, profiles: .profiles}'
}

# Local view: only what the instance itself defines.
lxd_instance_local_json() {
    lxd_instance_json "$1" |
        jq '{config: .config, devices: .devices, profiles: .profiles}'
}

require_lxc() {
    command -v lxc >/dev/null 2>&1 || fail "lxc was not found."
    command -v jq >/dev/null 2>&1 || fail "jq was not found (required to read structured LXD output)."
}

# cigo: render runs on the host, so jinja2 is a host dependency rather than a
# dependency of every container.
require_host_render() {
    command -v python3 >/dev/null 2>&1 ||
        fail "python3 was not found on the host (required by 'cigo: render')."
    python3 -c 'import jinja2' >/dev/null 2>&1 ||
        fail "python3-jinja2 is missing on the host (required by 'cigo: render'). Install it, for example: apt-get install python3-jinja2"
}

validate_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid container name: $1"
}

validate_var() {
    local name=$1 value=$2

    [[ $name =~ ^[A-Za-z_][A-Za-z0-9_.]+$ ]] ||
        fail "Invalid variable name: $name"
    [[ $value != *%* ]] || fail "Variable $name must not contain percent signs."
    [[ $value != *$'\n'* ]] || fail "Variable $name must not contain newlines."
}

is_builtin_var() {
    case $1 in
        cigo.name|cigo.image|cigo.image_version|cigo.image_codename|cigo.image_os|\
        cigo.arch|cigo.host|cigo.gateway|cigo.template|cigo.date) return 0 ;;
        *) return 1 ;;
    esac
}

# A secret source may be "NAME" (read the variable of the same name) or
# "NAME=ENV_VAR". The environment is only read while building render context.
secret_env_var() {
    local item=$1

    if [[ $item == *=* ]]; then
        printf '%s' "${item#*=}"
    else
        printf '%s' "$item"
    fi
}

# An absolute path is used as given. A relative path follows normal shell
# semantics and resolves against the current working directory, which is how an
# operator working inside a template directory expects it to behave. The
# result is stored and shown in preflight so the chosen file is never implicit.
secret_file_abspath() {
    local path=$1 dir

    if [[ $path == /* ]]; then
        printf '%s' "$path"
        return 0
    fi
    if dir=$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P); then
        printf '%s/%s' "${dir%/}" "$(basename -- "$path")"
    else
        printf '%s/%s' "${PWD%/}" "$path"
    fi
    return 0
}

validate_secrets() {
    local item name path env
    local -a resolved=()
    local -A seen=()

    for item in "${CLI_SECRET_FILES[@]}"; do
        [[ $item == *=* ]] || fail "--secret-file expects NAME=FILE: $item"
        name=${item%%=*}
        path=${item#*=}
        [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            fail "Invalid secret name: $name"
        [[ -n $path ]] || fail "--secret-file $name requires a file path."
        [[ ! ${seen[$name]+present} ]] || fail "Secret was specified more than once: $name"
        seen["$name"]=1
        path=$(secret_file_abspath "$path")
        [[ -f $path && -r $path ]] ||
            fail "Secret file is not a readable regular file: $path"
        resolved+=("$name=$path")
    done
    if ((${#resolved[@]})); then
        CLI_SECRET_FILES=("${resolved[@]}")
    fi

    for item in "${CLI_SECRET_ENV[@]}"; do
        [[ $item =~ ^[A-Za-z_][A-Za-z0-9_]*$ || $item =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            fail "--secret-env expects NAME or NAME=ENV_VAR: $item"
        name=${item%%=*}
        env=$(secret_env_var "$item")
        [[ ! ${seen[$name]+present} ]] || fail "Secret was specified more than once: $name"
        seen["$name"]=1
        [[ ${!env+x} ]] ||
            fail "--secret-env $name refers to unset environment variable: $env"
        [[ ${!env} != *$'\n'* ]] || fail "Environment variable $env must not contain newlines."
    done
}

valid_log_mode() {
    case $1 in
        journal|cloud-init|output|both|none) return 0 ;;
        *) return 1 ;;
    esac
}

strip_mask() {
    printf '%s' "${1%%/*}"
}

# lxc image info may query a remote server, so read all properties once.
# Cache in a file because image_property runs in command substitution.
load_image_info() {
    local file="$TMP_DIR/image-info.json"

    [[ -f $file ]] && return 0
    if ! lxc image list "$IMAGE" --format json > "$file" 2>/dev/null; then
        : > "$file"
        warn 'Could not load image information for %s.\n' "$IMAGE"
    fi
    return 0
}

image_property() {
    load_image_info
    jq -r --arg key "$1" '.[0].properties[$key] // empty' "$TMP_DIR/image-info.json"
}

resolve_network() {
    local net="" profile config_file

    if [[ -n $FROM_SOURCE && $EXISTING_CT == false ]]; then
        config_file="$TMP_DIR/network-source.json"
        if lxd_instance_expanded_json "$FROM_SOURCE" > "$config_file" 2>/dev/null; then
            net=$(jq -r '
                [.devices // {} | to_entries[]
                    | select(.value.type == "nic" and (.value.network // "") != "")
                    | .value.network][0] // empty' "$config_file")
        fi
    fi
    if [[ -z $net ]]; then
        for profile in "${PROFILES[@]}"; do
            if lxd_profile_json "$profile" > "$TMP_DIR/profile.json" 2>/dev/null; then
                net=$(jq -r '
                    [.devices // {} | to_entries[]
                        | select(.value.type == "nic" and (.value.network // "") != "")
                        | .value.network][0] // empty' "$TMP_DIR/profile.json")
            fi
            [[ -n $net ]] && break
        done
    fi
    if [[ -z $net ]]; then
        if lxd_profile_json default > "$TMP_DIR/profile.json" 2>/dev/null; then
            net=$(jq -r '
                [.devices // {} | to_entries[]
                    | select(.value.type == "nic" and (.value.network // "") != "")
                    | .value.network][0] // empty' "$TMP_DIR/profile.json")
        fi
    fi
    printf '%s' "$net"
}

set_var() {
    VARS["$1"]=$2
    VAR_ORIGIN["$1"]=$3
}

# Built-ins do not overwrite values explicitly defined in the template.
set_builtin_var() {
    [[ ${VAR_ORIGIN[$1]:-} == "template" || ${VAR_ORIGIN[$1]:-} == "--var" ]] && return 0
    set_var "$1" "$2" "cigo"
}

# Concatenated contents of every render source that exists, used to decide
# which built-ins the render context actually needs.
collect_render_sources() {
    local item src dst mode

    for item in "${ACTIONS[@]}"; do
        [[ ${item%%|*} == render ]] || continue
        read -r src dst mode <<< "${item#*|}"
        [[ -f $src && -r $src ]] && cat -- "$src"
    done
    return 0
}

# Template text refers to a built-in as %cigo.name%.
needs_builtin() {
    local text=$1 name=$2

    [[ $text == *"%$name%"* ]]
}

# A rendered host file refers to a built-in with its Jinja name, either
# {{ cigo_name }} or through the dotted map ({{ vars['cigo.name'] }}). A plain
# substring match may over-resolve slightly, which is harmless, while missing a
# reference would fail the render with StrictUndefined.
render_text_needs_builtin() {
    local text=$1 name=$2 jinja=${2//./_}

    [[ $text == *"%$name%"* || $text == *"$name"* || $text == *"$jinja"* ]]
}

# mode is "template" for the cloud-config/template text or "render" for the
# contents of rendered host files.
builtin_used() {
    local text=$1 name=$2 mode=${3:-template}

    if [[ $mode == render ]]; then
        render_text_needs_builtin "$text" "$name"
    else
        needs_builtin "$text" "$name"
    fi
}

needs_image_info() {
    local text=$1 mode=${2:-template}

    builtin_used "$text" cigo.image_version "$mode" ||
        builtin_used "$text" cigo.image_codename "$mode" ||
        builtin_used "$text" cigo.image_os "$mode" ||
        builtin_used "$text" cigo.arch "$mode"
}

compute_builtins() {
    local text=$1 mode=${2:-template} value net ipv4

    set_builtin_var "cigo.name" "$NAME"
    set_builtin_var "cigo.image" "$IMAGE"
    set_builtin_var "cigo.template" "$TEMPLATE"
    set_builtin_var "cigo.host" "$(hostname -s 2>/dev/null || hostname)"
    set_builtin_var "cigo.date" "$(date +%Y%m%d%H%M%S)"

    if needs_image_info "$text" "$mode"; then
        ui 'Loading image information for %s…\n' "$IMAGE"
        load_image_info
        value=$(image_property version)
        [[ -n $value ]] && set_builtin_var "cigo.image_version" "$value"
        value=$(image_property release)
        [[ -n $value ]] && set_builtin_var "cigo.image_codename" "$value"
        value=$(image_property os)
        [[ -n $value ]] && set_builtin_var "cigo.image_os" "$value"
        value=$(image_property architecture)
        [[ -n $value ]] && set_builtin_var "cigo.arch" "$value"
    fi

    if builtin_used "$text" cigo.gateway "$mode"; then
        net=$(resolve_network)
        if [[ -n $net ]]; then
            ipv4=$(lxc network get "$net" ipv4.address 2>/dev/null || true)
            if [[ -n $ipv4 && $ipv4 != none ]]; then
                set_builtin_var "cigo.gateway" "$(strip_mask "$ipv4")"
            fi
        fi
    fi
}

scan_meta() {
    local line rest key value

    while IFS= read -r line; do
        [[ $line == 'cigo: '* ]] || continue
        rest=${line#'cigo: '}
        key=${rest%% *}
        if [[ $rest == *' '* ]]; then value=${rest#* }; else value=""; fi

        case $key in
            image) IMAGE=$value ;;
            profile) PROFILES+=("$value") ;;
            from) FROM_SOURCE=$value ;;
            var)
                [[ $value == *=* ]] || fail "cigo: var expects NAME=VALUE: $value"
                local name=${value%%=*} var_value=${value#*=}
                if [[ $var_value == \"*\" && ${#var_value} -ge 2 ]] ||
                    [[ $var_value == \'*\' && ${#var_value} -ge 2 ]]; then
                    var_value=${var_value:1:${#var_value}-2}
                fi
                validate_var "$name" "$var_value"
                set_var "$name" "$var_value" "template"
                ;;
        esac
    done < "$TEMPLATE"
}

cli_config_has_key() {
    local item

    for item in "${CLI_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && return 0
    done
    return 1
}

# Whether the merged desired config (template plus --config) declares a key.
config_declared() {
    local item

    for item in "${CT_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && return 0
    done
    return 1
}

# Only template-declared keys become managed keys; --config is a one-off
# override and must never cause a later prune.
template_declares_key() {
    local item

    for item in "${TEMPLATE_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && return 0
    done
    return 1
}

cli_unset_has_key() {
    local key

    for key in "${CLI_UNSET[@]}"; do
        [[ $key == "$1" ]] && return 0
    done
    return 1
}

cli_removes_device() {
    local device

    for device in "${CLI_REMOVE_DEVICES[@]}"; do
        [[ $device == "$1" ]] && return 0
    done
    return 1
}

# Command-line options take precedence over template directives.
# image/profile/from are read by scan_meta, so CLI overrides are applied
# before built-ins are computed (keeping %cigo.image% accurate).
# --profile replaces the entire profile list from the template.
apply_cli_meta_overrides() {
    if [[ -n $CLI_IMAGE ]]; then IMAGE=$CLI_IMAGE; fi
    if [[ -n $CLI_FROM ]]; then FROM_SOURCE=$CLI_FROM; fi
    if ((${#CLI_PROFILES[@]})); then PROFILES=("${CLI_PROFILES[@]}"); fi
    return 0
}

# config/timeout/log are populated by parse_directives, so CLI overrides are
# applied afterwards. --config merges by key: replace matches, append new keys.
apply_cli_pipeline_overrides() {
    local item
    local -a merged=()

    if [[ -n $CLI_TIMEOUT ]]; then CLOUD_TIMEOUT=$CLI_TIMEOUT; fi
    if [[ -n $CLI_LOG ]]; then LOG_MODE=$CLI_LOG; fi

    if ((${#CLI_CONFIG[@]})); then
        for item in "${CT_CONFIG[@]}"; do
            cli_config_has_key "${item%%=*}" || merged+=("$item")
        done
        CT_CONFIG=("${merged[@]}" "${CLI_CONFIG[@]}")
    fi
    return 0
}

substitute_vars() {
    local text=$1 key leftover

    for key in "${!VARS[@]}"; do
        text=${text//"%$key%"/${VARS[$key]}}
    done

    leftover=$(printf '%s' "$text" | grep -oE '%[A-Za-z_][A-Za-z0-9_.]+%' | head -1 || true)
    if [[ -n $leftover ]]; then
        fail "Unknown variable $leftover (define it with 'cigo: var' or '--var')."
    fi
    printf '%s' "$text"
}

# Relative host sources are resolved against the directory of the template, so
# a template directory is self-contained regardless of the current directory.
resolve_host_source() {
    local path=$1

    if [[ $path != /* ]]; then
        [[ -n $TEMPLATE_DIR ]] ||
            fail "Cannot resolve relative host path without a template directory: $path"
        path="$TEMPLATE_DIR/$path"
    fi
    printf '%s' "$path"
}

parse_host_action() {
    local type=$1 value=$2 src dst

    [[ $value == *' '* ]] || {
        ACTIONS+=("$type|$value")
        return 0
    }
    src=${value%% *}
    dst=${value#* }
    [[ -n $src && -n $dst ]] || {
        ACTIONS+=("$type|$value")
        return 0
    }
    ACTIONS+=("$type|$(resolve_host_source "$src") $dst")
}

parse_directives() {
    local text=$1 line rest key value

    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]+cigo: ]]; then
            fail "The 'cigo: ' directive must start at column one: $line"
        fi
        [[ $line == 'cigo: '* ]] || continue
        rest=${line#'cigo: '}
        rest=${rest#"${rest%%[![:space:]]*}"}
        key=${rest%% *}
        if [[ $rest == *' '* ]]; then value=${rest#* }; else value=""; fi

        case $key in
            image|profile|from|var) ;;
            config)
                [[ $value == *=* ]] || fail "cigo: config expects KEY=VALUE: $value"
                CT_CONFIG+=("$value")
                ;;
            device) parse_device_directive "$value" ;;
            packages)
                [[ -n $value ]] || fail "cigo: packages requires a package list."
                ACTIONS+=("packages|$value")
                ;;
            copy-host|sync-host) parse_host_action "$key" "$value" ;;
            copy-ct) ACTIONS+=("copy-ct|$value") ;;
            sync-ct) ACTIONS+=("sync-ct|$value") ;;
            render)
                local render_src render_dst render_mode render_extra
                read -r render_src render_dst render_mode render_extra <<< "$value"
                [[ -n $render_src && -n $render_dst && -z $render_extra ]] ||
                    fail "cigo: render expects HOST_FILE CONTAINER_PATH [MODE]: $value"
                [[ $render_dst == /* ]] ||
                    fail "cigo: render destination must be an absolute path inside the container: $render_dst"
                if [[ -n $render_mode ]]; then
                    [[ $render_mode =~ ^0?[0-7]{3}$ ]] ||
                        fail "cigo: render mode must be an octal permission (for example 0600): $render_mode"
                fi
                ACTIONS+=("render|$(resolve_host_source "$render_src") $render_dst ${render_mode:-0600}")
                ;;
            run) ACTIONS+=("run|$value") ;;
            timeout)
                [[ $value =~ ^[0-9]+$ ]] || fail "cigo: timeout expects seconds: $value"
                CLOUD_TIMEOUT=$value
                ;;
            log)
                valid_log_mode "$value" ||
                    fail "cigo: log expects journal|cloud-init|output|both|none: $value"
                LOG_MODE=$value
                ;;
            *) fail "Unknown directive 'cigo: $key'." ;;
        esac
    done < <(printf '%s\n' "$text")
}

parse_device_directive() {    local value=$1 type name token key source path
    local -a words=() args=()
    local -A seen_keys=()

    read -r -a words <<< "$value"
    ((${#words[@]} >= 4)) ||
        fail "cigo: device expects TYPE NAME KEY=VALUE...: $value"
    type=${words[0]}
    name=${words[1]}
    [[ $type == disk || $type == proxy ]] ||
        fail "cigo: device supports only disk and proxy types: $type"
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $name != root ]] ||
        fail "Invalid or reserved LXD device name: $name"
    [[ ! ${DEVICE_TYPES[$name]+present} ]] ||
        fail "LXD device is declared more than once: $name"

    for token in "${words[@]:2}"; do
        [[ $token == *=* ]] || fail "Device option must be KEY=VALUE: $token"
        key=${token%%=*}
        [[ $key =~ ^[A-Za-z0-9_.-]+$ && $key != type && $key != name &&
            $key != volatile.* ]] ||
            fail "Invalid or reserved LXD device option: $key"
        [[ -n ${token#*=} ]] || fail "LXD device option requires a value: $key"
        [[ ! ${seen_keys[$key]+present} ]] ||
            fail "LXD device option is specified more than once for $name: $key"
        seen_keys["$key"]=1
        args+=("$token")
    done

    case $type in
        disk)
            [[ ${seen_keys[source]+present} && ${seen_keys[path]+present} ]] ||
                fail "Disk device $name requires source=HOST_PATH and path=CONTAINER_PATH."
            source=""
            path=""
            for token in "${args[@]}"; do
                case ${token%%=*} in
                    source) source=${token#*=} ;;
                    path) path=${token#*=} ;;
                esac
            done
            [[ $source == /* && $path == /* ]] ||
                fail "Disk device $name requires absolute host source and container paths."
            ;;
        proxy)
            [[ ${seen_keys[listen]+present} && ${seen_keys[connect]+present} ]] ||
                fail "Proxy device $name requires listen=ADDRESS and connect=ADDRESS."
            ;;
    esac

    DEVICE_NAMES+=("$name")
    DEVICE_TYPES["$name"]=$type
    DEVICE_ARGS["$name"]="${args[*]}"
}

# A short, human-readable name for the template, stored on the container so a
# later redeploy/check can tell which template a container came from.
template_label() {
    local requested=$1 label

    label=${requested%/}
    case $label in
        */template.yaml) label=${label%/template.yaml} ;;
        *.yaml) label=${label%.yaml} ;;
    esac
    label=${label##*/}
    [[ -n $label ]] || label=$requested
    printf '%s' "$label"
}

load_template() {
    local raw substituted varname candidate requested=$TEMPLATE
    local -a candidates=()

    # A template may be a file or a directory containing template.yaml.
    # Relative names are also searched next to the script and in templates/
    # so cigo.sh can be invoked from outside the project directory.
    if [[ $TEMPLATE == /* ]]; then
        candidates=("$TEMPLATE")
    else
        candidates=("$TEMPLATE" "$SCRIPT_DIR/$TEMPLATE" "$SCRIPT_DIR/templates/$TEMPLATE")
    fi
    TEMPLATE=""
    for candidate in "${candidates[@]}"; do
        if [[ -d $candidate ]]; then candidate="${candidate%/}/template.yaml"; fi
        if [[ -f $candidate ]]; then TEMPLATE=$candidate; break; fi
        if [[ -f $candidate.yaml ]]; then TEMPLATE=$candidate.yaml; break; fi
    done
    [[ -n $TEMPLATE ]] || fail "Cannot read template: $requested"
    TEMPLATE_DIR=$(cd -- "$(dirname -- "$TEMPLATE")" && pwd)
    TEMPLATE_LABEL=$(template_label "$requested")
    head -n 1 "$TEMPLATE" | grep -qx '#cloud-config' ||
        fail "Template must start with '#cloud-config': $TEMPLATE"

    raw=$(cat -- "$TEMPLATE")
    scan_meta
    apply_cli_meta_overrides
    [[ -n $IMAGE ]] || IMAGE=$DEFAULT_IMAGE

    compute_builtins "$raw"
    for varname in "${CLI_VARS[@]}"; do
        local name=${varname%%=*} value=${varname#*=}
        validate_var "$name" "$value"
        if [[ ! ${VARS[$name]+present} ]] && ! is_builtin_var "$name"; then
            fail "--var can only override a variable already defined by the template: $name"
        fi
        set_var "$name" "$value" "--var"
    done
    substituted=$(substitute_vars "$raw")
    parse_directives "$substituted"
    TEMPLATE_CONFIG=("${CT_CONFIG[@]}")
    apply_cli_pipeline_overrides

    # Render sources live on the host now, so built-ins referenced only inside
    # a rendered file are resolved here. The render context is built later, at
    # action time, which keeps this from needing a second substitution pass.
    local render_text
    render_text=$(collect_render_sources)
    [[ -z $render_text ]] || compute_builtins "$render_text" render

    USER_DATA_FILE="$TMP_DIR/user-data.yaml"
    printf '%s\n' "$substituted" | awk '!/^cigo: /' > "$USER_DATA_FILE"
    head -n 1 "$USER_DATA_FILE" | grep -qx '#cloud-config' ||
        fail "Template does not start with '#cloud-config' after removing directives."

        # Secrets and the host render environment are only needed by verbs that run
    # pipeline actions. configure and adopt never render, so a template with
    # render actions must not force jinja2 or secret files on the host.
    if verb_runs_actions; then
        validate_secrets
        local has_render=false action
        for action in "${ACTIONS[@]}"; do
            [[ ${action%%|*} == render ]] && has_render=true
        done
        if ((${#CLI_SECRET_FILES[@]} || ${#CLI_SECRET_ENV[@]})); then
            [[ $has_render == true ]] ||
                fail "--secret-file and --secret-env require at least one cigo: render action."
        fi
        [[ $has_render == false ]] || require_host_render
    fi
}

vars_table() {
    local key
    local -a keys=()

    ((${#VARS[@]})) || return 0
    mapfile -t keys < <(printf '%s\n' "${!VARS[@]}" | LC_ALL=C sort)
    ui 'Variables:\n'
    for key in "${keys[@]}"; do
        ui '  %%%s%% = %s  (%s)\n' "$key" "${VARS[$key]}" "${VAR_ORIGIN[$key]}"
    done
}

print_action() {
    local type=${1%%|*} data=${1#*|}

    case $type in
        packages) ui '  packages: %s\n' "$data" ;;
        copy-host) ui '  copy from host: %s\n' "$data" ;;
        sync-host) ui '  sync from host: %s\n' "$data" ;;
        copy-ct) ui '  copy from container: %s\n' "$data" ;;
        sync-ct) ui '  sync from container: %s\n' "$data" ;;
        render) ui '  render: %s\n' "$data" ;;
        run) ui '  command: %s\n' "$data" ;;
    esac
}

# Return the source of a config value if the template or CLI overrides it.
config_origin() {
    local item

    for item in "${CLI_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && { printf '%s' '--config'; return 0; }
    done
    for item in "${CT_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && { printf '%s' 'template'; return 0; }
    done
    return 1
}

config_value() {
    local item

    for item in "${CT_CONFIG[@]}"; do
        [[ ${item%%=*} == "$1" ]] && { printf '%s' "${item#*=}"; return 0; }
    done
    return 1
}

print_inherited() {
    local item device origin

    ui 'Source (from): %s\n' "$FROM_SOURCE"
    if ((${#INHERIT_KEYS[@]} == 0 && ${#INHERIT_DEVICES[@]} == 0 && ${#PROXY_DEVICES[@]} == 0)); then
        ui '  nothing to inherit\n'
        return 0
    fi
    if ((${#INHERIT_KEYS[@]})); then
        ui '  config (%d):\n' "${#INHERIT_KEYS[@]}"
        for item in "${INHERIT_KEYS[@]}"; do
            if origin=$(config_origin "$item"); then
                ui '    %s = %s  -> %s (%s)\n' "$item" "${INHERIT_CONFIG[$item]}" \
                    "$(config_value "$item")" "$origin"
            else
                ui '    %s = %s\n' "$item" "${INHERIT_CONFIG[$item]}"
            fi
        done
    fi
    if ((${#INHERIT_DEVICES[@]})); then
        ui '  devices (%d):\n' "${#INHERIT_DEVICES[@]}"
        for device in "${INHERIT_DEVICES[@]}"; do
            ui '    %s (%s)\n' "$device" "$(device_type "$device")"
        done
    fi
    if ((${#PROXY_DEVICES[@]})); then
        ui '  proxy devices (%d, handled after start):\n' "${#PROXY_DEVICES[@]}"
        for device in "${PROXY_DEVICES[@]}"; do
            ui '    %s  %s -> %s\n' \
                "$device" "$(device_value "$device" listen)" "$(device_value "$device" connect)"
        done
    fi
}

print_preflight() {
    local item key current secret device

    ui '\n=== Preflight ===\n'
    ui 'Verb: %s\nContainer: %s\n' "$VERB" "$NAME"
    if [[ $EXISTING_CT == true ]]; then
        ui 'Template: %s\n' "${TEMPLATE:-(none)}"
        ui 'Managed config keys: %s\n' "$( ((${#MANAGED_KEYS[@]})) && printf '%s' "${MANAGED_KEYS[*]}" || printf 'none')"
    else
        ui 'Image: %s\nTemplate: %s\n' "$IMAGE" "$TEMPLATE"
    fi
    if ((${#PROFILES[@]})); then
        ui 'Profiles: %s\n' "${PROFILES[*]}"
    fi
    if [[ -n $FROM_SOURCE && $EXISTING_CT == false ]]; then
        print_inherited
    fi
    vars_table
    if ((${#CT_CONFIG[@]})); then
        if [[ $EXISTING_CT == true ]]; then
            ui 'Declared container config:\n'
            for item in "${CT_CONFIG[@]}"; do
                key=${item%%=*}
                current=$(instance_config_value "$key")
                if [[ $current == "${item#*=}" ]]; then
                    ui '  %s=%s (unchanged)\n' "$key" "$current"
                elif [[ -z $current ]]; then
                    ui '  %s=%s (new)\n' "$key" "${item#*=}"
                else
                    ui '  %s=%s -> %s\n' "$key" "$current" "${item#*=}"
                fi
            done
        else
            ui 'Container config:\n'
            for item in "${CT_CONFIG[@]}"; do ui '  %s\n' "$item"; done
        fi
    fi
    if ((${#CLI_UNSET[@]})); then
        ui 'Config to remove: %s\n' "${CLI_UNSET[*]}"
    fi
    if ((${#DEVICE_NAMES[@]})); then
        ui 'Declared LXD devices (reconciled on every run):\n'
        for device in "${DEVICE_NAMES[@]}"; do
            ui '  %s %s %s\n' "$device" "${DEVICE_TYPES[$device]}" "${DEVICE_ARGS[$device]}"
        done
    fi
    if ((${#CLI_REMOVE_DEVICES[@]})); then
        ui 'Devices to remove: %s\n' "${CLI_REMOVE_DEVICES[*]}"
    fi
    if ((${#CLI_SECRET_FILES[@]} || ${#CLI_SECRET_ENV[@]})); then
        ui 'Secrets (values are not displayed; render-only):\n'
        for secret in "${CLI_SECRET_FILES[@]}"; do
            ui '  %s  (file: %s)\n' "${secret%%=*}" "${secret#*=}"
        done
        for secret in "${CLI_SECRET_ENV[@]}"; do
            ui '  %s  (environment: %s)\n' "${secret%%=*}" "$(secret_env_var "$secret")"
        done
    fi
    if ((${#ACTIONS[@]})); then
        ui 'Actions (in declaration order):\n'
        for item in "${ACTIONS[@]}"; do print_action "$item"; done
    else
        ui 'Actions: none\n'
    fi
}

read_source() {
    local device
    local -a devices=()

    [[ -n $FROM_SOURCE ]] || return 0
    ui 'Reading source container configuration: %s…\n' "$FROM_SOURCE"
    lxc info "$FROM_SOURCE" >/dev/null 2>&1 ||
        fail "Source container $FROM_SOURCE is not available."

    lxd_instance_expanded_json "$FROM_SOURCE" > "$TMP_DIR/source.json" ||
        fail "Could not read expanded config for source container $FROM_SOURCE."

    while IFS= read -r device; do
        [[ -n $device ]] || continue
        INHERIT_CONFIG["$device"]=$(jq -r --arg key "$device" '.config[$key] // empty' \
            "$TMP_DIR/source.json")
        INHERIT_KEYS+=("$device")
    done < <(jq -r '.config // {} | keys[]
        | select(test("^(volatile\\.|image\\.|cloud-init\\.|user\\.cigo\\.)") | not)' \
        "$TMP_DIR/source.json")

    mapfile -t devices < <(
        jq -r '.devices // {} | to_entries[]
            | select(.key != "root" and .key != "eth0" and .value.type != "nic")
            | .key' "$TMP_DIR/source.json")

    for device in "${devices[@]}"; do
        [[ ! ${DEVICE_TYPES[$device]+present} ]] ||
            fail "Device $device is declared by both cigo: from and cigo: device; use only one source for this device."
        if [[ $(device_type "$device") == proxy ]]; then
            PROXY_DEVICES+=("$device")
        else
            INHERIT_DEVICES+=("$device")
        fi
    done
}

validate_device_name_conflicts() {
    local device profile device_type

    ((${#DEVICE_NAMES[@]})) || return 0
    if [[ $EXISTING_CT == true ]]; then
        lxd_instance_local_json "$NAME" > "$TMP_DIR/device-local.json" ||
            fail "Could not read local device config for $NAME."
        lxd_instance_expanded_json "$NAME" > "$TMP_DIR/device-expanded.json" ||
            fail "Could not read expanded device config for $NAME."
        while IFS= read -r profile; do
            [[ -n $profile ]] || continue
            lxd_profile_json "$profile" > "$TMP_DIR/device-profile.json" ||
                fail "Could not read LXD profile $profile while checking device names."
            for device in "${DEVICE_NAMES[@]}"; do
                if jq -e --arg device "$device" '.devices[$device] != null' \
                    "$TMP_DIR/device-profile.json" >/dev/null; then
                    fail "Device $device is defined by LXD profile $profile; choose a different device name."
                fi
            done
        done < <(jq -r '.profiles[]?' "$TMP_DIR/device-local.json")
        for device in "${DEVICE_NAMES[@]}"; do
            if jq -e --arg device "$device" '.devices[$device] != null' \
                "$TMP_DIR/device-local.json" >/dev/null; then
                device_type=$(jq -r --arg device "$device" \
                    '.devices[$device].type // empty' "$TMP_DIR/device-local.json")
                [[ $device_type == "${DEVICE_TYPES[$device]}" ]] ||
                    fail "Device $device already exists as type $device_type, not ${DEVICE_TYPES[$device]}; rename or remove it manually."
                continue
            fi
            if jq -e --arg device "$device" '.devices[$device] != null' \
                "$TMP_DIR/device-expanded.json" >/dev/null; then
                fail "Device $device is inherited from an LXD profile and cannot be managed by cigo; choose a different device name."
            fi
        done
        return 0
    fi

    if ((${#PROFILES[@]})); then
        for profile in "${PROFILES[@]}"; do
            check_profile_device_names "$profile"
        done
    else
        check_profile_device_names default
    fi
}

check_profile_device_names() {
    local profile=$1 device

    lxd_profile_json "$profile" > "$TMP_DIR/device-profile.json" ||
        fail "Could not read LXD profile $profile while checking device names."
    for device in "${DEVICE_NAMES[@]}"; do
        if jq -e --arg device "$device" '.devices[$device] != null' \
            "$TMP_DIR/device-profile.json" >/dev/null; then
            fail "Device $device is already defined by LXD profile $profile; choose a different device name."
        fi
    done
}

device_type() {
    jq -r --arg device "$1" '.devices[$device].type // empty' "$TMP_DIR/source.json"
}

device_args() {
    local device=$1 key value

    while IFS= read -r key; do
        [[ $key == type || $key == name || $key == volatile.* ]] && continue
        value=$(jq -r --arg device "$device" --arg key "$key" \
            '.devices[$device][$key] | if type == "string" then . else tostring end' \
            "$TMP_DIR/source.json")
        printf '%s=%s\n' "$key" "$value"
    done < <(jq -r --arg device "$device" '.devices[$device] | keys[]' "$TMP_DIR/source.json")
}

device_value() {
    jq -r --arg device "$1" --arg key "$2" \
        '.devices[$device][$key] // empty' "$TMP_DIR/source.json"
}

apply_from() {
    local key device dtype origin
    local -a args=()

    for key in "${INHERIT_KEYS[@]}"; do
        if origin=$(config_origin "$key"); then
            ui 'Source config %s overridden by %s.\n' "$key" "$origin"
            continue
        fi
        lxc config set "$NAME" "$key" "${INHERIT_CONFIG[$key]}"
    done

    for device in "${INHERIT_DEVICES[@]}"; do
        dtype=$(device_type "$device")
        [[ -n $dtype ]] || fail "Could not determine device type for $device."
        mapfile -t args < <(device_args "$device")
        lxc config device add "$NAME" "$device" "$dtype" "${args[@]}"
        ui 'Inherited device: %s (%s)\n' "$device" "$dtype"
    done
}

# Convert "tcp:0.0.0.0:2223" to "tcp:0.0.0.0:2224". Values without a
# trailing port number (for example, Unix sockets) are returned unchanged.
listen_next_port() {
    local listen=$1

    if [[ $listen =~ ^(.*:)([0-9]+)$ ]]; then
        printf '%s%s' "${BASH_REMATCH[1]}" "$((BASH_REMATCH[2] + 1))"
    else
        printf '%s' "$listen"
    fi
}

# Empty input uses the suggestion; a numeric port inherits its address.
listen_from_input() {
    local input=$1 suggested=$2 prefix

    if [[ -z $input ]]; then
        printf '%s' "$suggested"
        return 0
    fi
    if [[ $input =~ ^[0-9]+$ ]]; then
        if [[ $suggested =~ ^(.*:)[0-9]+$ ]]; then
            prefix=${BASH_REMATCH[1]}
        else
            prefix='tcp:0.0.0.0:'
        fi
        printf '%s%s' "$prefix" "$input"
        return 0
    fi
    printf '%s' "$input"
}

handle_proxy_devices() {
    local device listen connect answer custom suggested arg
    local -a args=() custom_args=()

    ((${#PROXY_DEVICES[@]})) || return 0

    for device in "${PROXY_DEVICES[@]}"; do
        listen=$(device_value "$device" listen)
        connect=$(device_value "$device" connect)
        mapfile -t args < <(device_args "$device")

        if [[ $ASSUME_YES == true ]]; then
            warn 'Skipping proxy %s (%s) with --yes.\n' "$device" "$listen"
            warn '  manual handoff: lxc config device remove %s %s\n' "$FROM_SOURCE" "$device"
            warn '  then: lxc config device add %s %s proxy listen=%s connect=%s\n' \
                "$NAME" "$device" "$listen" "$connect"
            continue
        fi

        suggested=$(listen_next_port "$listen")
        ui '\nProxy device %s (%s -> %s) conflicts with the source container.\n' \
            "$device" "$listen" "$connect"
        while :; do
            err 'Choose: [h]andoff / [c]ustom port / [s]kip / [q]uit: '
            read -r answer || answer=q
            case $answer in
                o|O|h|H)
                    lxc config device remove "$FROM_SOURCE" "$device" ||
                        fail "Could not remove $device from $FROM_SOURCE."
                    if lxc config device add "$NAME" "$device" proxy "${args[@]}"; then
                        ui 'Proxy device %s handed off from the source.\n' "$device"
                    elif lxc config device add "$FROM_SOURCE" "$device" proxy "${args[@]}"; then
                        fail "Could not add proxy $device to $NAME; the source device was restored."
                    else
                        fail "Could not add proxy $device to $NAME or restore it to $FROM_SOURCE. Restore it manually with: lxc config device add $FROM_SOURCE $device proxy ..."
                    fi
                    break
                    ;;
                v|V|c|C)
                    printf 'New listen address [%s]: ' "$suggested" >&2
                    read -r custom || custom=""
                    custom=$(listen_from_input "$custom" "$suggested")
                    custom_args=()
                    for arg in "${args[@]}"; do
                        if [[ $arg == listen=* ]]; then
                            custom_args+=("listen=$custom")
                        else
                            custom_args+=("$arg")
                        fi
                    done
                    if lxc config device add "$NAME" "$device" proxy "${custom_args[@]}" 2>/dev/null; then
                        ui 'Proxy device %s added on %s.\n' "$device" "$custom"
                        break
                    fi
                    suggested=$(listen_next_port "$custom")
                    if [[ $suggested != "$custom" ]]; then
                        warn 'Could not add listen address %s (the port may be in use); try %s.\n' \
                            "$custom" "$suggested"
                    else
                        warn 'Could not add listen address %s; try another value.\n' "$custom"
                    fi
                    ;;
                p|P|s|S)
                    warn 'Skipping proxy device %s.\n' "$device"
                    warn '  manual: lxc config device add %s %s proxy listen=%s connect=%s\n' \
                        "$NAME" "$device" "$listen" "$connect"
                    break
                    ;;
                u|U|q|Q)
                    fail "Cancelled by user."
                    ;;
            esac
        done
    done
}

cloud_init_logs_desc() {
    case $LOG_MODE in
        journal) printf 'journalctl -t cloud-init' ;;
        cloud-init) printf '/var/log/cloud-init.log' ;;
        output) printf '/var/log/cloud-init-output.log' ;;
        both) printf 'journal + cloud-init-output.log' ;;
        none) printf 'disabled' ;;
    esac
}

stop_log_followers() {
    ct_exec sh -c '
        command -v pkill >/dev/null 2>&1 || exit 0
        pkill -f "var/log/cloud-init" 2>/dev/null
        pkill -f "journalctl -f -n 0 -t cloud-init" 2>/dev/null
        exit 0' >/dev/null 2>&1 || true
}

wait_for_cloud_init() {
    local rc=0

    if ! ct_exec sh -c 'command -v cloud-init >/dev/null 2>&1'; then
        warn 'cloud-init is not installed in the container; skipping the wait.\n'
        return 0
    fi

    ui '\nWaiting for cloud-init (log: %s, timeout: %s seconds)...\n' \
        "$(cloud_init_logs_desc)" "$CLOUD_TIMEOUT"

    timeout "$CLOUD_TIMEOUT" lxc exec "$NAME" -- sh -s -- "$LOG_MODE" <<'REMOTE' || rc=$?
mode=$1
use_journal=0
logs=""
case $mode in
    journal) use_journal=1 ;;
    cloud-init) logs="/var/log/cloud-init.log" ;;
    output) logs="/var/log/cloud-init-output.log" ;;
    both) use_journal=1; logs="/var/log/cloud-init-output.log" ;;
    none) ;;
esac
if [ "$use_journal" = 1 ] && ! command -v journalctl >/dev/null 2>&1; then
    use_journal=0
    logs="/var/log/cloud-init.log $logs"
fi
pids=""
trap 'kill $pids 2>/dev/null' EXIT
if [ "$use_journal" = 1 ]; then
    journalctl -f -n 0 -t cloud-init -o cat 2>/dev/null &
    pids="$pids $!"
fi
for f in $logs; do
    [ -e "$f" ] || touch "$f"
    if [ "$f" = /var/log/cloud-init.log ]; then
        tail -n +1 -F "$f" 2>/dev/null | grep --line-buffered -v '\[DEBUG\]' &
    else
        tail -n +1 -F "$f" 2>/dev/null &
    fi
    pids="$pids $!"
done
cloud-init status --wait >/dev/null 2>&1
rc=$?
sleep 0.3
kill $pids 2>/dev/null
pkill -f "journalctl -f -n 0 -t cloud-init" 2>/dev/null
pkill -f "var/log/cloud-init" 2>/dev/null
exit $rc
REMOTE

    stop_log_followers

    case $rc in
        0) ui 'Cloud-init completed.\n' ;;
        124)
            warn 'Cloud-init did not finish within %s seconds.\n' "$CLOUD_TIMEOUT"
            fail "Cloud-init timed out; inspect: lxc info $NAME --show-log"
            ;;
        *)
            warn 'Cloud-init failed with exit status %s.\n' "$rc"
            ct_exec cloud-init status --long 2>&1 || true
            ct_exec journalctl -t cloud-init -n 30 -o cat 2>&1 || true
            fail "Cloud-init failed in $NAME"
            ;;
    esac
}

action_packages() {
    local -a wanted=() missing=()
    local pkg

    read -r -a wanted <<< "$1"
    for pkg in "${wanted[@]}"; do
        ct_exec dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if ((${#missing[@]} == 0)); then
        ui '  all packages are already installed; skipping.\n'
        return 0
    fi
    ui '  missing: %s\n' "${missing[*]}"
    ct_exec apt-get update -qq
    ct_exec env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${missing[@]}"
}

# Host paths are mounted as temporary disk devices with shift=true rather
# than streamed through tar; without shifting, files would appear as nobody.
# MOUNTPOINT is set directly because command substitution would run in a
# subshell, leaving STAGE_DEVICE unset in the parent shell.
mount_host_path() {
    STAGE_DEVICE="cigo-src-$$"
    MOUNTPOINT=/mnt/cigo-src
    lxc config device add "$NAME" "$STAGE_DEVICE" disk \
        "source=$1" "path=$MOUNTPOINT" shift=true >/dev/null
}

unmount_host_path() {
    [[ -n $STAGE_DEVICE ]] || return 0
    lxc config device remove "$NAME" "$STAGE_DEVICE" >/dev/null
    STAGE_DEVICE=""
    MOUNTPOINT=""
}

action_copy_host() {
    local src=$1 dst=$2

    [[ -e $src ]] || fail "Host source does not exist: $src"
    if [[ -d $src ]]; then
        mount_host_path "$src"
        ct_exec mkdir -p -- "$dst"
        ct_exec rsync -a "$MOUNTPOINT/" "$dst/"
    else
        mount_host_path "$(dirname -- "$src")"
        ct_exec mkdir -p -- "$(dirname -- "$dst")"
        ct_exec rsync -a "$MOUNTPOINT/$(basename -- "$src")" "$dst"
    fi
    unmount_host_path
}

action_sync_host() {
    local src=$1 dst=$2

    [[ -d $src ]] || fail "sync-host requires a directory: $src"
    mount_host_path "$src"
    ct_exec mkdir -p -- "$dst"
    ct_exec rsync -a --delete "$MOUNTPOINT/" "$dst/"
    unmount_host_path
}

action_copy_ct() {
    local src_ct=$1 path=$2 base

    lxc info "$src_ct" >/dev/null 2>&1 || fail "Container is not available: $src_ct"
    ct_exec_at "$src_ct" sh -c 'test -e "$1" || test -L "$1"' sh "$path" >/dev/null 2>&1 ||
        fail "Path does not exist in $src_ct: $path"

    base=$(basename -- "$path")
    if ct_exec_at "$src_ct" test -d "$path"; then
        REMOTE_STAGE_DIR=$(ct_exec mktemp -d /tmp/cigo-stage.XXXXXX)
        ct_exec_at "$src_ct" tar -C "$(dirname -- "$path")" -cf - "$base" |
            lxc exec "$NAME" -- tar -C "$REMOTE_STAGE_DIR" -xf -
        ct_exec mkdir -p -- "$path"
        ct_exec rsync -a "$REMOTE_STAGE_DIR/$base/" "$path/"
        ct_exec rm -rf -- "$REMOTE_STAGE_DIR"
        REMOTE_STAGE_DIR=""
    else
        ct_exec_at "$src_ct" tar -C "$(dirname -- "$path")" -cf - "$base" |
            lxc exec "$NAME" -- tar -C "$(dirname -- "$path")" -xf -
    fi
}

action_sync_ct() {
    local src_ct=$1 path=$2 base

    lxc info "$src_ct" >/dev/null 2>&1 || fail "Container is not available: $src_ct"
    ct_exec_at "$src_ct" test -d "$path" >/dev/null 2>&1 ||
        fail "sync-ct requires a directory: $src_ct:$path"

    reject_shared_mount_sync "$src_ct" "$path"

    base=$(basename -- "$path")
    REMOTE_STAGE_DIR=$(ct_exec mktemp -d /tmp/cigo-stage.XXXXXX)
    ct_exec_at "$src_ct" tar -C "$(dirname -- "$path")" -cf - "$base" |
        lxc exec "$NAME" -- tar -C "$REMOTE_STAGE_DIR" -xf -
    ct_exec mkdir -p -- "$path"
    ct_exec rsync -a --delete "$REMOTE_STAGE_DIR/$base/" "$path/"
    ct_exec rm -rf -- "$REMOTE_STAGE_DIR"
    REMOTE_STAGE_DIR=""
}

reject_shared_mount_sync() {
    local source_json="$TMP_DIR/sync-source.json"
    local target_json="$TMP_DIR/sync-target.json"
    local shared

    lxd_instance_expanded_json "$1" > "$source_json" ||
        fail "Could not read expanded config for source container $1."
    lxd_instance_expanded_json "$NAME" > "$target_json" ||
        fail "Could not read expanded config for target container $NAME."
    shared=$(jq -n -r --arg path "$2" --slurpfile source "$source_json" --slurpfile target "$target_json" '
        def mounts($instance; $path):
            ($instance.devices // {} | to_entries
                | map(select(.value.type == "disk"
                    and (.value.path as $mount_path
                        | ($path == $mount_path
                            or ($path | startswith($mount_path + "/")))))
                    | [.value.source, .value.path]));
        mounts($source[0]; $path) as $source_mounts
        | mounts($target[0]; $path) as $target_mounts
        | if any($source_mounts[]; . as $mount | any($target_mounts[]; . == $mount))
          then "true" else "false" end
    ') || fail "Could not compare source and target disk devices."
    [[ $shared != true ]] ||
        fail "sync-ct would sync a path shared by both containers; refusing to risk data loss: $2"
}

# cigo: render runs entirely on the host. Only the rendered result is pushed
# into the container, so no container needs python3-jinja2 and the plaintext
# secret never enters the container's temporary storage.
write_render_context() {
    local key item name path env context
    local -a keys=()

    context="$TMP_DIR/context"
    rm -rf -- "$context"
    (umask 077; mkdir -p -- "$context/vars" "$context/secrets")

    mapfile -t keys < <(printf '%s\n' "${!VARS[@]}" | LC_ALL=C sort)
    for key in "${keys[@]}"; do
        (umask 077; printf '%s' "${VARS[$key]}" > "$context/vars/$key")
    done

    for item in "${CLI_SECRET_FILES[@]}"; do
        name=${item%%=*}
        path=${item#*=}
        (umask 077; cp -- "$path" "$context/secrets/$name") ||
            fail "Could not stage secret file for the render context: $path"
    done

    for item in "${CLI_SECRET_ENV[@]}"; do
        name=${item%%=*}
        env=$(secret_env_var "$item")
        (umask 077; printf '%s' "${!env}" > "$context/secrets/$name")
    done
}

write_render_script() {
    local script="$TMP_DIR/render.py"

    [[ -f $script ]] && return 0
    cat > "$script" <<'PY'
import os
import sys

import jinja2

src, dst, context_dir, mode = sys.argv[1:]

def read_values(directory, strip_final_newline=False):
    values = {}
    for entry in os.scandir(directory):
        if entry.is_file(follow_symlinks=False):
            with open(entry.path, encoding="utf-8") as handle:
                value = handle.read()
            if strip_final_newline and value.endswith("\n"):
                value = value[:-1]
                if value.endswith("\r"):
                    value = value[:-1]
            values[entry.name] = value
    return values

raw = read_values(os.path.join(context_dir, "vars"))
secrets = read_values(os.path.join(context_dir, "secrets"), strip_final_newline=True)
context = dict(raw)
context.update({key.replace(".", "_"): value for key, value in raw.items() if "." in key})
context["vars"] = raw
context["secrets"] = secrets
env = jinja2.Environment(keep_trailing_newline=True, undefined=jinja2.StrictUndefined)
try:
    with open(src, encoding="utf-8") as handle:
        template = env.from_string(handle.read())
    rendered = template.render(**context)
except (jinja2.TemplateError, OSError, UnicodeDecodeError) as exc:
    sys.stderr.write("render %s: %s\n" % (src, exc))
    raise SystemExit(1)
file_mode = int(mode, 8)
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, file_mode)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    os.fchmod(fd, file_mode)
    handle.write(rendered)
PY
}

# LXD's file transfer occasionally fails with a transient forkfile error, so a
# short bounded retry keeps one flaky transfer from failing the whole deploy.
push_rendered_file() {
    local src=$1 dst=$2 mode=$3 attempt

    for attempt in 1 2 3; do
        if lxc file push --quiet --mode="$mode" --uid=0 --gid=0 "$src" "$dst"; then
            return 0
        fi
        if ((attempt < 3)); then
            warn 'LXD file transfer failed; retrying (%s/3)…\n' "$attempt"
            sleep 1
        fi
    done
    return 1
}

# Render on the host, then replace the destination in the container through a
# sibling temporary file so a failed transfer cannot leave a half-written file.
action_render() {
    local src=$1 dst=$2 mode=$3 rendered stage

    [[ $dst == /* ]] ||
        fail "cigo: render destination must be an absolute path inside the container: $dst"
    [[ -f $src && -r $src ]] || fail "Render source does not exist on the host: $src"

    write_render_script
    write_render_context
    rendered="$TMP_DIR/rendered.$(printf '%s' "$dst" | tr '/' '_')"
    python3 "$TMP_DIR/render.py" "$src" "$rendered" "$TMP_DIR/context" "$mode" ||
        fail "Rendering failed: $src"

    if [[ $CHECK_ONLY == true || $DRY_RUN == true ]]; then
        ui '  would render: %s -> %s (%s)\n' "$src" "$dst" "$mode"
        return 0
    fi

    ct_exec mkdir -p -- "$(dirname -- "$dst")"
    stage="${dst}.cigo-tmp.$$"
    if ! push_rendered_file "$rendered" "$NAME$stage" "$mode"; then
        lxc exec "$NAME" -- rm -f -- "$stage" </dev/null >/dev/null 2>&1 || true
        fail "Could not push the rendered file into $NAME: $dst"
    fi
    if ! ct_exec mv -f -- "$stage" "$dst"; then
        lxc exec "$NAME" -- rm -f -- "$stage" </dev/null >/dev/null 2>&1 || true
        fail "Could not move the rendered file into place: $dst"
    fi
}

run_action() {
    local type=${1%%|*} data=${1#*|} src="" dst="" mode="" extra=""

    case $type in
        packages) action_packages "$data" ;;
        copy-host|sync-host|copy-ct|sync-ct)
            [[ $data == *' '* ]] ||
                fail "'cigo: $type' expects two values: $data"
            src=${data%% *}
            dst=${data#* }
            case $type in
                copy-host) action_copy_host "$src" "$dst" ;;
                sync-host) action_sync_host "$src" "$dst" ;;
                copy-ct) action_copy_ct "$src" "$dst" ;;
                sync-ct) action_sync_ct "$src" "$dst" ;;
            esac
            ;;
        render)
            read -r src dst mode extra <<< "$data"
            [[ -n $src && -z $extra ]] ||
                fail "cigo: render expects TEMPLATE [DESTINATION] [MODE]: $data"
            dst=${dst:-}
            mode=${mode:-0600}
            [[ $mode =~ ^0?[0-7]{3}$ ]] ||
                fail "cigo: render mode must be an octal permission (for example 0600): $mode"
            action_render "$src" "$dst" "$mode"
            ;;
        run) ct_exec sh -c "$data" ;;
    esac
}

execute_actions() {
    local item

    ((${#ACTIONS[@]})) || return 0
    ui '\nRunning actions:\n'
    for item in "${ACTIONS[@]}"; do
        print_action "$item"
    done
    confirm "Run these actions?" || fail "Cancelled."

    for item in "${ACTIONS[@]}"; do
        ui '-> %s\n' "${item#*|}"
        run_action "$item"
    done
}

write_dumped_user_data() {
    [[ -n $DUMP_USER_DATA ]] || return 0
    (umask 077; cp -- "$USER_DATA_FILE" "$DUMP_USER_DATA" &&
        chmod 600 -- "$DUMP_USER_DATA") ||
        fail "Could not write rendered user-data to $DUMP_USER_DATA."
    ui 'Rendered user-data written to %s (mode 0600).\n' "$DUMP_USER_DATA"
}

validate_actions() {
    local item type data src dst

    for item in "${ACTIONS[@]}"; do
        type=${item%%|*}
        data=${item#*|}
        case $type in
            copy-host|sync-host)
                [[ $data == *' '* ]] ||
                    fail "'cigo: $type' expects SOURCE DESTINATION: $data"
                src=${data%% *}
                if [[ $type == sync-host ]]; then
                    [[ -d $src ]] || fail "sync-host source must be a directory: $src"
                else
                    [[ -e $src ]] || fail "Host source does not exist: $src"
                fi
                ;;
            copy-ct|sync-ct)
                [[ $data == *' '* ]] ||
                    fail "'cigo: $type' expects CONTAINER PATH: $data"
                src=${data%% *}
                dst=${data#* }
                lxc info "$src" >/dev/null 2>&1 ||
                    fail "Source container is not available: $src"
                if [[ $type == sync-ct ]]; then
                    ct_exec_at "$src" test -d "$dst" ||
                        fail "sync-ct source must be an existing directory: $src:$dst"
                else
                    ct_exec_at "$src" sh -c 'test -e "$1" || test -L "$1"' sh "$dst" ||
                        fail "Source path does not exist: $src:$dst"
                fi
                ;;
            render)
                read -r src dst extra <<< "$data"
                [[ -f $src && -r $src ]] ||
                    fail "Render source does not exist on the host: $src"
                [[ $dst == /* ]] ||
                    fail "cigo: render destination must be an absolute path inside the container: $dst"
                ;;
        esac
    done
}

validate_renders() {
    local item src dst mode

    for item in "${ACTIONS[@]}"; do
        [[ ${item%%|*} == render ]] || continue
        read -r src dst mode <<< "${item#*|}"
        action_render "$src" "$dst" "${mode:-0600}"
    done
}

validate_user_data() {
    if command -v cloud-init >/dev/null 2>&1; then
        cloud-init schema --config-file "$USER_DATA_FILE" ||
            fail "cloud-init schema validation failed."
    else
        warn 'cloud-init is not installed on the host; cloud-config schema validation was skipped.\n'
        warn 'Install cloud-init to validate the bootstrap section as well.\n'
    fi
}

# --- existing container: config, devices and cigo metadata ---------------

# Read one key from the instance's local (not profile-expanded) config.
instance_config_value() {
    jq -r --arg key "$1" '.config[$key] // empty' "$TMP_DIR/current-local.json" 2>/dev/null || true
}

refresh_local_config() {
    lxd_instance_local_json "$NAME" > "$TMP_DIR/current-local.json" ||
        fail "Could not read the current configuration of $NAME."
}

read_managed_keys() {
    local value

    MANAGED_KEYS=()
    value=$(instance_config_value "$META_MANAGED")
    [[ -n $value ]] || return 0
    IFS=',' read -r -a MANAGED_KEYS <<< "$value"
    return 0
}

# The new managed-key set. On create it is the template's key list; afterwards
# it is the previous set plus newly declared keys, minus keys that are no
# longer declared (declarative run) or were explicitly unset.
managed_keys_csv() {
    local item key
    local -A keep=()
    local -a keys=()

    if [[ $VERB == create ]]; then
        for item in "${TEMPLATE_CONFIG[@]}"; do
            key=${item%%=*}
            cli_unset_has_key "$key" && continue
            config_declared "$key" || continue
            keep["$key"]=1
        done
    else
        for key in "${MANAGED_KEYS[@]}"; do
            [[ -n $key ]] || continue
            cli_unset_has_key "$key" && continue
            if ((${#TEMPLATE_CONFIG[@]})); then
                config_declared "$key" || continue
            fi
            keep["$key"]=1
        done
        for item in "${TEMPLATE_CONFIG[@]}"; do
            key=${item%%=*}
            cli_unset_has_key "$key" && continue
            config_declared "$key" || continue
            keep["$key"]=1
        done
    fi

    ((${#keep[@]})) || return 0
    mapfile -t keys < <(printf '%s\n' "${!keep[@]}" | LC_ALL=C sort)
    ((${#keys[@]})) || return 0
    local IFS=,
    printf '%s' "${keys[*]}"
}

# Metadata is written last, so a run that fails half-way never claims that
# cigo manages a container it did not finish preparing.
write_cigo_metadata() {
    local stamp=$1 key value current

    for key in "$META_VERSION" "$META_TEMPLATE" "$META_CREATED" "$META_ADOPTED"; do
        case $key in
            "$META_VERSION") value=$CIGO_VERSION ;;
            "$META_TEMPLATE") value=$TEMPLATE_LABEL ;;
            "$META_CREATED") [[ $stamp == created ]] || continue; value=$(date -u +%Y-%m-%dT%H:%M:%SZ) ;;
            "$META_ADOPTED") [[ $stamp == adopted ]] || continue; value=$(date -u +%Y-%m-%dT%H:%M:%SZ) ;;
        esac
        [[ -n $value ]] || continue
        current=$(lxc config get "$NAME" "$key" 2>/dev/null || true)
        [[ $current == "$value" ]] && continue
        lxc config set "$NAME" "$key" "$value" >/dev/null ||
            fail "Could not write $key on $NAME."
        ui 'Metadata: %s=%s\n' "$key" "$value"
    done

    # Imperative configure (no template, no unset) leaves the key list alone.
    if [[ $VERB != create ]] && ((${#TEMPLATE_CONFIG[@]} == 0 && ${#CLI_UNSET[@]} == 0)); then
        return 0
    fi
    value=$(managed_keys_csv)
    current=$(lxc config get "$NAME" "$META_MANAGED" 2>/dev/null || true)
    [[ $current == "$value" ]] && return 0
    if [[ -z $value ]]; then
        lxc config unset "$NAME" "$META_MANAGED" >/dev/null 2>&1 || true
        ui 'Metadata: %s cleared\n' "$META_MANAGED"
        return 0
    fi
    lxc config set "$NAME" "$META_MANAGED" "$value" >/dev/null ||
        fail "Could not write $META_MANAGED on $NAME."
    ui 'Metadata: %s=%s\n' "$META_MANAGED" "$value"
}

# Applies the desired config. In plan mode it prints the difference and sets
# DRIFT instead of touching LXD.
apply_runtime_config() {
    local item key desired current

    for item in "${CT_CONFIG[@]}"; do
        key=${item%%=*}
        desired=${item#*=}
        current=$(instance_config_value "$key")
        if [[ $current == "$desired" ]]; then
            [[ $PLAN_MODE == true ]] && ui '  = %s = %s\n' "$key" "$desired"
            continue
        fi
        if [[ $PLAN_MODE == true ]]; then
            if [[ -z $current ]]; then
                ui '  + %s = %s\n' "$key" "$desired"
            else
                ui '  ~ %s: %s -> %s\n' "$key" "$current" "$desired"
            fi
            DRIFT=true
            continue
        fi
        if ! lxc config set "$NAME" "$key" "$desired"; then
            fail "LXD could not update $key on the existing container. The setting may require a stopped container or recreation; earlier config changes may already have applied."
        fi
        ui 'Updated container config: %s=%s\n' "$key" "$desired"
    done
}

# Removes keys cigo wrote earlier that the template no longer declares. Only
# keys recorded in managed-keys are candidates, so manual settings survive.
prune_managed_config() {
    local key current

    ((${#TEMPLATE_CONFIG[@]})) || return 0
    for key in "${MANAGED_KEYS[@]}"; do
        [[ -n $key ]] || continue
        config_declared "$key" && continue
        cli_unset_has_key "$key" && continue
        current=$(instance_config_value "$key")
        [[ -n $current ]] || continue
        if [[ $PLAN_MODE == true ]]; then
            ui '  - %s = %s  (no longer declared)\n' "$key" "$current"
            DRIFT=true
            continue
        fi
        lxc config unset "$NAME" "$key" ||
            fail "Could not remove $key from $NAME."
        ui 'Removed container config: %s (was %s)\n' "$key" "$current"
    done
}

apply_cli_unset() {
    local key current

    for key in "${CLI_UNSET[@]}"; do
        if config_declared "$key"; then
            fail "--unset $key conflicts with a config key declared by the template."
        fi
        current=$(instance_config_value "$key")
        if [[ -z $current ]]; then
            [[ $PLAN_MODE == true ]] && ui '  = %s (not set)\n' "$key"
            continue
        fi
        if [[ $PLAN_MODE == true ]]; then
            ui '  - %s = %s  (--unset)\n' "$key" "$current"
            DRIFT=true
            continue
        fi
        lxc config unset "$NAME" "$key" ||
            fail "Could not unset $key on $NAME."
        ui 'Unset container config: %s (was %s)\n' "$key" "$current"
    done
}

apply_removed_devices() {
    local device

    ((${#CLI_REMOVE_DEVICES[@]})) || return 0
    for device in "${CLI_REMOVE_DEVICES[@]}"; do
        if [[ ${DEVICE_TYPES[$device]+present} ]]; then
            fail "--remove-device $device conflicts with a device declared by the template."
        fi
        if ! jq -e --arg device "$device" '.devices[$device] != null' \
            "$TMP_DIR/current-local.json" >/dev/null; then
            fail "Device $device does not exist on $NAME."
        fi
        if [[ $PLAN_MODE == true ]]; then
            ui '  - device %s\n' "$device"
            DRIFT=true
            continue
        fi
        lxc config device remove "$NAME" "$device" ||
            fail "Could not remove device $device from $NAME."
        ui 'Removed device: %s\n' "$device"
    done
}

device_has_argument() {
    local device=$1 wanted=$2 argument
    local -a arguments=()

    read -r -a arguments <<< "${DEVICE_ARGS[$device]}"
    for argument in "${arguments[@]}"; do
        [[ ${argument%%=*} == "$wanted" ]] && return 0
    done
    return 1
}

reconcile_device() {
    local device=$1 type=${DEVICE_TYPES[$1]} key value current current_type
    local item
    local -a args=() current_keys=()

    read -r -a args <<< "${DEVICE_ARGS[$device]}"
    lxd_instance_local_json "$NAME" > "$TMP_DIR/device-local.json" ||
        fail "Could not read local device config for $NAME."

    if jq -e --arg device "$device" '.devices[$device] != null' \
        "$TMP_DIR/device-local.json" >/dev/null; then
        current_type=$(jq -r --arg device "$device" \
            '.devices[$device].type // empty' "$TMP_DIR/device-local.json")
        [[ $current_type == "$type" ]] ||
            fail "Device $device already exists as type $current_type, not $type; rename or remove it manually."

        for item in "${args[@]}"; do
            key=${item%%=*}
            value=${item#*=}
            current=$(jq -r --arg device "$device" --arg key "$key" \
                '(.devices[$device] // {}) as $config
                | if $config | has($key) then
                    ($config[$key] | if type == "string" then . else tostring end)
                  else "" end' \
                "$TMP_DIR/device-local.json")
            if [[ $current == "$value" ]]; then
                [[ $PLAN_MODE == true ]] && ui '  = device %s %s=%s\n' "$device" "$key" "$value"
                continue
            fi
            if [[ $PLAN_MODE == true ]]; then
                if [[ -z $current ]]; then
                    ui '  + device %s %s=%s\n' "$device" "$key" "$value"
                else
                    ui '  ~ device %s %s: %s -> %s\n' "$device" "$key" "$current" "$value"
                fi
                DRIFT=true
                continue
            fi
            if ! lxc config device set "$NAME" "$device" "$key" "$value"; then
                if [[ $type == proxy && $key == listen ]]; then
                    fail "Could not update proxy device $device listen address; it may already be in use. cigo does not change declared ports automatically; earlier device changes may already have applied."
                fi
                fail "Could not update $type device $device option $key; earlier device changes may already have applied."
            fi
            ui 'Updated device %s: %s=%s\n' "$device" "$key" "$value"
        done

        mapfile -t current_keys < <(jq -r --arg device "$device" \
            '.devices[$device] | keys[] | select(. != "type" and . != "name" and (startswith("volatile.") | not))' \
            "$TMP_DIR/device-local.json")
        for key in "${current_keys[@]}"; do
            device_has_argument "$device" "$key" && continue
            if [[ $PLAN_MODE == true ]]; then
                ui '  - device %s %s  (no longer declared)\n' "$device" "$key"
                DRIFT=true
                continue
            fi
            if ! lxc config device unset "$NAME" "$device" "$key"; then
                fail "Could not remove undeclared option $key from device $device; earlier device changes may already have applied."
            fi
            ui 'Removed undeclared device option: %s %s\n' "$device" "$key"
        done
    else
        if [[ $PLAN_MODE == true ]]; then
            ui '  + device %s (%s) %s\n' "$device" "$type" "${DEVICE_ARGS[$device]}"
            DRIFT=true
            return 0
        fi
        if ! lxc config device add "$NAME" "$device" "$type" "${args[@]}"; then
            if [[ $type == proxy ]]; then
                fail "Could not add proxy device $device. Check whether its listen address is available; cigo does not change declared ports automatically."
            fi
            fail "Could not add disk device $device."
        fi
        ui 'Added device: %s (%s)\n' "$device" "$type"
    fi
}

apply_declared_devices() {
    local phase=$1 device

    for device in "${DEVICE_NAMES[@]}"; do
        [[ ${DEVICE_TYPES[$device]} == "$phase" ]] || continue
        reconcile_device "$device"
    done
}

# Reports config keys that neither the template nor cigo owns. Informational
# only: it never changes the exit status.
report_unmanaged_config() {
    local key candidate managed

    while IFS= read -r key; do
        [[ -n $key ]] || continue
        config_declared "$key" && continue
        cli_unset_has_key "$key" && continue
        managed=false
        for candidate in "${MANAGED_KEYS[@]}"; do
            [[ $candidate == "$key" ]] && managed=true
        done
        [[ $managed == true ]] && continue
        ui '  ? %s = %s  (set outside cigo)\n' "$key" "$(instance_config_value "$key")"
    done < <(jq -r '.config // {} | keys[]
        | select(test("^(volatile\\.|image\\.|cloud-init\\.|user\\.cigo\\.)") | not)' \
        "$TMP_DIR/current-local.json" | LC_ALL=C sort)
}

report_undeclared_devices() {
    local device

    while IFS= read -r device; do
        [[ -n $device ]] || continue
        [[ ${DEVICE_TYPES[$device]+present} ]] && continue
        cli_removes_device "$device" && continue
        ui '  ? device %s  (present but not declared)\n' "$device"
    done < <(jq -r '.devices // {} | to_entries[]
        | select(.key != "root" and .value.type != "nic") | .key' \
        "$TMP_DIR/current-local.json" | LC_ALL=C sort)
}

# Shared by --check and --dry-run. Every apply_* function switches to reporting
# when PLAN_MODE is set, so the plan cannot drift from what a real run does.
print_drift_report() {
    ui '\n=== Config ===\n'
    if ((${#CT_CONFIG[@]})); then
        apply_runtime_config
    else
        ui '  no config keys declared\n'
    fi
    prune_managed_config
    apply_cli_unset

    ui '\n=== Devices ===\n'
    if ((${#DEVICE_NAMES[@]})); then
        apply_declared_devices disk
        apply_declared_devices proxy
    else
        ui '  no devices declared\n'
    fi
    apply_removed_devices

    ui '\n=== Not managed by cigo ===\n'
    report_unmanaged_config
    report_undeclared_devices
}

reconcile_container() {
    local action_count=${#ACTIONS[@]}

    if [[ $action_count -gt 0 && $VERB != redeploy ]]; then
        ui 'Note: the template declares %d pipeline action(s); %s does not run them.\n' \
            "$action_count" "$VERB"
    fi

    if [[ $CHECK_ONLY == true || $DRY_RUN == true ]]; then
        PLAN_MODE=true
        if [[ $VERB == redeploy ]]; then
            validate_actions
            validate_renders
        fi
        print_drift_report
        if [[ $CHECK_ONLY == true ]]; then
            if [[ $DRIFT == true ]]; then
                ui '\nDrift detected: %s differs from the declared state.\n' "$NAME"
                exit 1
            fi
            ui '\nNo drift: %s matches the declared state.\n' "$NAME"
            exit 0
        fi
        ui '\nDry run complete; no LXD state was changed.\n'
        exit 0
    fi

    confirm "Apply $VERB to $NAME?" || fail "Cancelled; no changes were made."

    apply_runtime_config
    prune_managed_config
    apply_cli_unset
    apply_declared_devices disk
    apply_declared_devices proxy
    apply_removed_devices
    if [[ $VERB == redeploy ]]; then
        execute_actions
    fi

    case $VERB in
        adopt) write_cigo_metadata adopted ;;
        *) write_cigo_metadata existing ;;
    esac

    case $VERB in
        adopt) ui '\nContainer adopted: %s\n' "$NAME" ;;
        redeploy) ui '\nRe-deploy completed: %s\n' "$NAME" ;;
        *) ui '\nConfiguration applied: %s\n' "$NAME" ;;
    esac
}

validate_unset_conflicts() {
    local key

    for key in "${CLI_UNSET[@]}"; do
        config_declared "$key" &&
            fail "--unset $key conflicts with a config key declared by the template."
    done
    return 0
}

validate_remove_device_conflicts() {
    local device

    for device in "${CLI_REMOVE_DEVICES[@]}"; do
        [[ ${DEVICE_TYPES[$device]+present} ]] &&
            fail "--remove-device $device conflicts with a device declared by the template."
    done
    return 0
}

run_verb() {
    [[ -n $NAME ]] || fail "Required option missing: --name."
    if [[ $VERB != configure ]]; then
        [[ -n $TEMPLATE ]] || fail "Required option missing: --template."
    fi
    validate_name "$NAME"
    require_lxc
    lxc info >/dev/null 2>&1 || fail "LXD is not available."

    TMP_DIR=$(mktemp -d)
    if lxc info "$NAME" >/dev/null 2>&1; then
        EXISTING_CT=true
    fi

    if [[ $VERB == create && $EXISTING_CT == true ]]; then
        fail "Container $NAME already exists; use 'redeploy' to reapply a template, or 'configure' to change LXD config only."
    fi
    if [[ $VERB != create && $EXISTING_CT == false ]]; then
        fail "Container $NAME does not exist; use 'create' to create it."
    fi

    if [[ -n $TEMPLATE ]]; then
        load_template
    else
        CT_CONFIG=("${CLI_CONFIG[@]}")
        if ((${#CT_CONFIG[@]} == 0 && ${#CLI_UNSET[@]} == 0 && ${#CLI_REMOVE_DEVICES[@]} == 0)); then
            fail "Nothing to configure: pass --config, --unset, --remove-device, or --template."
        fi
    fi

    if [[ $EXISTING_CT == true ]]; then
        refresh_local_config
        read_managed_keys
        if ((${#CLI_UNSET[@]})); then validate_unset_conflicts; fi
        if ((${#CLI_REMOVE_DEVICES[@]})); then validate_remove_device_conflicts; fi
        if [[ -z $(instance_config_value "$META_VERSION") ]]; then
            case $VERB in
                redeploy)
                    fail "Container $NAME is not managed by cigo (no $META_VERSION); use 'adopt' to take it over, or 'configure' to change LXD config only." ;;
                adopt) ;;
                *)
                    ui 'Note: %s is not managed by cigo yet; configure only changes live LXD state.\n' "$NAME" ;;
            esac
        fi
    else
        read_source
    fi
    validate_device_name_conflicts

    if [[ -n $DUMP_USER_DATA ]]; then write_dumped_user_data; fi

    print_preflight

    if [[ $EXISTING_CT == true ]]; then
        reconcile_container
        return 0
    fi

    if [[ $CHECK_ONLY == true ]]; then
        validate_actions
        validate_renders
        validate_user_data
        ui 'Template check passed; no LXD state was changed.\n'
        return 0
    fi
    if [[ $DRY_RUN == true ]]; then
        validate_actions
        validate_renders
        validate_user_data
        ui 'Dry run complete; no LXD state was changed.\n'
        return 0
    fi

    create_new_container
}

create_new_container() {
    local item profile
    local -a profile_args=()

    confirm "Create $NAME from image $IMAGE?" || fail "Creation cancelled."

    for profile in "${PROFILES[@]}"; do
        profile_args+=(-p "$profile")
    done
    lxc init "$IMAGE" "$NAME" "${profile_args[@]}" < /dev/null

    apply_from
    for item in "${CT_CONFIG[@]}"; do
        lxc config set "$NAME" "${item%%=*}" "${item#*=}"
    done
    ui 'Container config applied.\n'
    apply_declared_devices disk

    lxc config set "$NAME" cloud-init.user-data - < "$USER_DATA_FILE"
    ui 'Cloud-init user-data uploaded.\n'

    lxc start "$NAME"
    wait_for_cloud_init
    apply_declared_devices proxy
    handle_proxy_devices
    execute_actions

    write_cigo_metadata created

    ui '\nContainer is ready: %s\n' "$NAME"
}

# Verbs only differ in which layers they apply, so one option parser serves
# all of them and each verb rejects the options that cannot mean anything.
verb_runs_actions() {
    [[ $VERB == create || $VERB == redeploy ]]
}

validate_config_key() {
    local key=$1 what=$2

    [[ $key =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        fail "Invalid LXD config key for $what: $key"
    [[ $key != volatile.* ]] ||
        fail "$what cannot target an LXD-managed key: $key"
    [[ $key != "$META_PREFIX"* ]] ||
        fail "$what cannot target cigo metadata: $key"
}

validate_device_name_argument() {
    local device=$1 what=$2

    [[ $device =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $device != root ]] ||
        fail "Invalid device name for $what: $device"
}

parse_options() {
    while (($#)); do
        case $1 in
            --name)
                (($# >= 2)) || fail "Missing value after --name."
                NAME=$2; shift 2 ;;
            --template)
                (($# >= 2)) || fail "Missing value after --template."
                TEMPLATE=$2; shift 2 ;;
            --image)
                (($# >= 2)) || fail "Missing value after --image."
                [[ -n $2 ]] || fail "--image requires a non-empty value."
                CLI_IMAGE=$2; shift 2 ;;
            --from)
                (($# >= 2)) || fail "Missing value after --from."
                [[ -n $2 ]] || fail "--from requires a non-empty value."
                CLI_FROM=$2; shift 2 ;;
            --profile)
                (($# >= 2)) || fail "Missing value after --profile."
                [[ -n $2 ]] || fail "--profile requires a non-empty value."
                CLI_PROFILES+=("$2"); shift 2 ;;
            --config)
                (($# >= 2)) || fail "Missing value after --config."
                [[ $2 == *=* ]] || fail "--config expects KEY=VALUE: $2"
                CLI_CONFIG+=("$2"); shift 2 ;;
            --unset)
                (($# >= 2)) || fail "Missing value after --unset."
                CLI_UNSET+=("$2"); shift 2 ;;
            --remove-device)
                (($# >= 2)) || fail "Missing value after --remove-device."
                CLI_REMOVE_DEVICES+=("$2"); shift 2 ;;
            --timeout)
                (($# >= 2)) || fail "Missing value after --timeout."
                [[ $2 =~ ^[0-9]+$ ]] || fail "--timeout expects a number of seconds: $2"
                CLI_TIMEOUT=$2; shift 2 ;;
            --log)
                (($# >= 2)) || fail "Missing value after --log."
                valid_log_mode "$2" ||
                    fail "--log expects journal|cloud-init|output|both|none: $2"
                CLI_LOG=$2; shift 2 ;;
            --var)
                (($# >= 2)) || fail "Missing value after --var."
                [[ $2 == *=* ]] || fail "--var expects NAME=VALUE: $2"
                CLI_VARS+=("$2"); shift 2 ;;
            --secret-file)
                (($# >= 2)) || fail "Missing value after --secret-file."
                [[ $2 == *=* ]] || fail "--secret-file expects NAME=FILE: $2"
                CLI_SECRET_FILES+=("$2"); shift 2 ;;
            --secret-env)
                (($# >= 2)) || fail "Missing value after --secret-env."
                CLI_SECRET_ENV+=("$2"); shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --check)
                CHECK_ONLY=true; shift ;;
            --dump-user-data)
                (($# >= 2)) || fail "Missing value after --dump-user-data."
                [[ -n $2 ]] || fail "--dump-user-data requires a file path."
                DUMP_USER_DATA=$2; shift 2 ;;
            -y|--yes)
                ASSUME_YES=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                usage >&2; fail "Unknown option: $1" ;;
        esac
    done

    local key device
    if [[ $VERB != create ]]; then
        [[ -z $CLI_IMAGE ]] || fail "--image applies only to create."
        [[ -z $CLI_FROM ]] || fail "--from applies only to create."
        ((${#CLI_PROFILES[@]} == 0)) || fail "--profile applies only to create; profiles are set at creation time."
        [[ -z $CLI_TIMEOUT ]] || fail "--timeout applies only to create."
        [[ -z $CLI_LOG ]] || fail "--log applies only to create."
        [[ -z $DUMP_USER_DATA ]] || fail "--dump-user-data applies only to create."
    fi
    if [[ $VERB != configure && $VERB != redeploy ]]; then
        ((${#CLI_UNSET[@]} == 0)) || fail "--unset applies only to configure and redeploy."
        ((${#CLI_REMOVE_DEVICES[@]} == 0)) ||
            fail "--remove-device applies only to configure and redeploy."
    fi
    if ! verb_runs_actions; then
        ((${#CLI_SECRET_FILES[@]} == 0 && ${#CLI_SECRET_ENV[@]} == 0)) ||
            fail "--secret-file and --secret-env apply only to create and redeploy, which run actions."
    fi

    for key in "${CLI_UNSET[@]}"; do
        validate_config_key "$key" "--unset"
    done
    for device in "${CLI_REMOVE_DEVICES[@]}"; do
        validate_device_name_argument "$device" "--remove-device"
    done
    return 0
}

main() {
    local command=${1:-}
    [[ -n $command ]] || { usage >&2; exit 2; }
    shift

    case $command in
        create|redeploy|configure|adopt)
            VERB=$command
            parse_options "$@"
            run_verb
            ;;
        -h|--help) usage ;;
        -V|--version|version) printf 'cigo %s\n' "$CIGO_VERSION" ;;
        *) usage >&2; fail "Unknown command: $command" ;;
    esac
}

main "$@"
