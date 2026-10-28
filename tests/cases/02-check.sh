#!/usr/bin/env bash
# --check must validate a good template and reject a template whose render
# references an undefined variable, without creating anything.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name check)

output=$(cigo_expect_ok "$CIGO" create --name "$name" --template "$FIXTURES/basic" \
    --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "Template check passed" "valid template accepted"
assert_no_container "$name"

output=$(cigo_expect_fail "$CIGO" create --name "$name" --template "$FIXTURES/broken" \
    --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "Rendering failed" "broken render detected"
assert_contains "$output" "THIS_VARIABLE_DOES_NOT_EXIST" "undefined variable named"
assert_no_container "$name"
