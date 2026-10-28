#!/usr/bin/env bash
# `cigo: from` must carry eligible config and devices to the new container and
# let the template override individual keys.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

source_ct=$(ct_name source)
target_ct=$(ct_name target)
register_ct "$source_ct"
register_ct "$target_ct"

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-from.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/data"
printf 'inherited\n' > "$work/data/marker.txt"

cigo_create "$source_ct" "$FIXTURES/device" --config boot.autostart=true \
    --var "DATA_DIR=$work/data" >/dev/null
assert_eq "192MiB" "$(lxc config get "$source_ct" limits.memory)" "source config"

output=$(cigo_create "$target_ct" "$FIXTURES/from-target" --from "$source_ct" \
    --config limits.memory=320MiB)
assert_contains "$output" "Inherited device: it-data" "device inherited"
assert_contains "$output" "limits.memory = 192MiB  -> 320MiB" "override shown in preflight"

assert_eq "320MiB" "$(lxc config get "$target_ct" limits.memory)" "template override wins"
assert_eq "true" "$(lxc config get "$target_ct" boot.autostart)" "config inherited"
device=$(lxc config device show "$target_ct")
assert_contains "$device" "source: $work/data" "inherited device present"
assert_eq "inherited" "$(ct_run "$target_ct" "cat /mnt/it-data/marker.txt")" \
    "inherited device is mounted"
