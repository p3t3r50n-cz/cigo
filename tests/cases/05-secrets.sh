#!/usr/bin/env bash
# Secrets must reach the renderer from a file and from the environment, must
# never appear in the output, and must produce a private file.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name secrets)
register_ct "$name"

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-secret.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
printf 'file-secret-value\n' > "$work/secret"
chmod 600 "$work/secret"

output=$(cigo_create "$name" "$FIXTURES/secret" --secret-file "IT_SECRET=$work/secret")
assert_contains "$output" "IT_SECRET  (file:" "secret source shown without its value"
assert_not_contains "$output" "file-secret-value" "file secret value not printed"
assert_eq "file-secret-value" \
    "$(ct_run "$name" "sed -n 's/^secret = //p' /etc/cigo-it/secret.conf")" \
    "secret rendered from file"
assert_file_mode "$name" /etc/cigo-it/secret.conf 600

# A rotated file must be picked up by the next run.
printf 'rotated-secret-value\n' > "$work/secret"
cigo_expect_ok "$CIGO" create --name "$name" --template "$FIXTURES/secret" \
    --image "$CIGO_IT_IMAGE" --yes --secret-file "IT_SECRET=$work/secret" >/dev/null
assert_eq "rotated-secret-value" \
    "$(ct_run "$name" "sed -n 's/^secret = //p' /etc/cigo-it/secret.conf")" \
    "rotated secret applied on re-deploy"

# The environment is a first-class source as well.
env_name=$(ct_name secrets-env)
register_ct "$env_name"
output=$(IT_SECRET=env-secret-value cigo_create "$env_name" "$FIXTURES/secret" \
    --secret-env IT_SECRET)
assert_contains "$output" "IT_SECRET  (environment:" "environment source reported"
assert_not_contains "$output" "env-secret-value" "environment secret not printed"
assert_eq "env-secret-value" \
    "$(ct_run "$env_name" "sed -n 's/^secret = //p' /etc/cigo-it/secret.conf")" \
    "secret rendered from environment"

# An unset variable must fail before any container work happens.
output=$(cigo_expect_fail "$CIGO" create --name "$(ct_name secrets-missing)" \
    --template "$FIXTURES/secret" --image "$CIGO_IT_IMAGE" \
    --secret-env IT_SECRET_UNSET_VAR)
assert_contains "$output" "unset environment variable" "unset secret reported"
assert_no_container "$(ct_name secrets-missing)"
