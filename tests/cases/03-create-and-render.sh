#!/usr/bin/env bash
# Create a container and prove the rendered file lands with the right content,
# mode and owner. This is the regression test for rendering never reaching the
# container at all.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name create)
register_ct "$name"

output=$(cigo_create "$name" "$FIXTURES/basic")
assert_contains "$output" "Container is ready" "container created"

content=$(ct_run "$name" "cat /etc/cigo-it/app.conf")
assert_contains "$content" "greeting = hello" "variable rendered"
assert_contains "$content" "container = $name" "built-in cigo_name rendered"

assert_file_mode "$name" /etc/cigo-it/app.conf 640
assert_owner "$name" /etc/cigo-it/app.conf root:root
