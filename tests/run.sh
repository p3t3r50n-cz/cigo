#!/usr/bin/env bash
# Integration test runner for cigo.
#
#   ./tests/run.sh                  run every case
#   ./tests/run.sh 03 05            run cases whose filename matches a pattern
#   CIGO_IT_KEEP=1 ./tests/run.sh   keep containers for debugging
#   CIGO_IT_IMAGE=<image> ./tests/run.sh
#
# Requires a working LXD server. Containers are named with a unique prefix and
# removed afterwards, so existing containers are never touched.

set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1

IT_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-state.XXXXXX")
export IT_STATE_DIR
: > "$IT_STATE_DIR/containers"

# shellcheck source=lib.sh
source ./lib.sh

export CIGO_IT_PREFIX="${CIGO_IT_PREFIX:-cigo-it-$(date +%H%M%S)-$$}"

cleanup() {
    local status=$? name
    if [[ ${CIGO_IT_KEEP:-0} == 1 ]]; then
        printf '\nKeeping containers (CIGO_IT_KEEP=1):\n'
        sed 's/^/  /' "$IT_STATE_DIR/containers" 2>/dev/null
        printf 'State directory: %s\n' "$IT_STATE_DIR"
        return "$status"
    fi
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        lxc delete --force "$name" >/dev/null 2>&1 ||
            printf 'warning: could not delete %s\n' "$name" >&2
    done < "$IT_STATE_DIR/containers"
    rm -rf -- "$IT_STATE_DIR"
    return "$status"
}
trap cleanup EXIT INT TERM HUP

printf 'cigo integration tests\n'
printf '  cigo:    %s\n' "$CIGO"
printf '  image:   %s\n' "$CIGO_IT_IMAGE"
printf '  prefix:  %s\n' "$CIGO_IT_PREFIX"

require_lxd
require_jinja2

shopt -s nullglob
cases=(cases/*.sh)
if ((${#cases[@]} == 0)); then
    printf 'No test cases found.\n' >&2
    exit 1
fi

selected=()
if (($#)); then
    for pattern in "$@"; do
        for case_file in "${cases[@]}"; do
            [[ $case_file == *"$pattern"* ]] && selected+=("$case_file")
        done
    done
    ((${#selected[@]})) || { printf 'No case matched: %s\n' "$*" >&2; exit 1; }
else
    selected=("${cases[@]}")
fi

failed=()
started=$SECONDS

for case_file in "${selected[@]}"; do
    name=$(basename "$case_file" .sh)
    printf '\n== %s ==\n' "$name"
    output=$(bash "$case_file" 2>&1)
    status=$?
    printf '%s\n' "$output"
    if ((status != 0)); then
        failed+=("$name")
        printf '  -> FAILED (exit %s)\n' "$status"
    fi
done

printf '\n==========================================\n'
printf '\nSummary: %s run, %s failed, %ss\n' \
    "${#selected[@]}" "${#failed[@]}" "$((SECONDS - started))"
if ((${#failed[@]})); then
    printf 'Failed: %s\n' "${failed[*]}"
    exit 1
fi
printf 'All tests passed.\n'
