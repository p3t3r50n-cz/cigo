#!/usr/bin/env bash
# Re-deploy must update container config and re-render files that are already
# in place, without recreating the container.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name redeploy)
register_ct "$name"

cigo_create "$name" "$FIXTURES/basic" >/dev/null
assert_eq "hello" "$(ct_run "$name" "sed -n 's/^greeting = //p' /etc/cigo-it/app.conf")" \
    "initial render"

output=$(cigo_expect_ok "$CIGO" create --name "$name" --template "$FIXTURES/basic" \
    --image "$CIGO_IT_IMAGE" --yes --var GREETING=bye --config limits.memory=256MiB)
assert_contains "$output" "Re-deploy completed" "re-deploy reported"
assert_contains "$output" "Updated container config: limits.memory=256MiB" "config updated"

assert_eq "bye" "$(ct_run "$name" "sed -n 's/^greeting = //p' /etc/cigo-it/app.conf")" \
    "render refreshed on re-deploy"
assert_eq "256MiB" "$(lxc config get "$name" limits.memory)" "live config applied"
