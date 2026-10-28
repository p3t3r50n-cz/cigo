#!/usr/bin/env bash
# --dry-run must show the plan, exercise every render, and change nothing.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name dryrun)
output=$(cigo_expect_ok "$CIGO" create --name "$name" --template "$FIXTURES/basic" \
    --image "$CIGO_IT_IMAGE" --dry-run)

assert_contains "$output" "Dry run complete" "dry-run finished"
assert_contains "$output" "would render" "render was previewed"
assert_contains "$output" "/etc/cigo-it/app.conf" "destination shown in the plan"
assert_contains "$output" "limits.memory=192MiB" "container config shown"
assert_no_container "$name"
