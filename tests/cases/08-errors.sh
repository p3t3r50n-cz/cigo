#!/usr/bin/env bash
# Invalid input must fail with an actionable message and must not create
# anything. Each case is a guard that a real bug once slipped past.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-errors.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

name=$(ct_name errors)

# Render source that does not exist on the host.
mkdir -p "$work/missing-source"
printf '#cloud-config\ncigo: render files/nope.j2 /etc/cigo-it/nope\n' \
    > "$work/missing-source/template.yaml"
output=$(cigo_expect_fail "$CIGO" create --name "$name" \
    --template "$work/missing-source" --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "does not exist on the host" "missing render source reported"
assert_no_container "$name"

# A device name owned by the root disk cannot be managed.
mkdir -p "$work/bad-device"
printf '#cloud-config\ncigo: device disk root source=/tmp path=/data\n' \
    > "$work/bad-device/template.yaml"
output=$(cigo_expect_fail "$CIGO" create --name "$name" \
    --template "$work/bad-device" --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "reserved" "reserved device name rejected"
assert_no_container "$name"

# Unknown directives must not be ignored silently.
mkdir -p "$work/unknown"
printf '#cloud-config\ncigo: teleport somewhere\n' > "$work/unknown/template.yaml"
output=$(cigo_expect_fail "$CIGO" create --name "$name" \
    --template "$work/unknown" --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "Unknown directive" "unknown directive rejected"
assert_no_container "$name"

# A missing template file.
output=$(cigo_expect_fail "$CIGO" create --name "$name" \
    --template "$work/no-such-template" --image "$CIGO_IT_IMAGE" --check)
assert_contains "$output" "Cannot read template" "missing template reported"
assert_no_container "$name"

# A secret file that does not exist, proving the check runs before creation.
output=$(cigo_expect_fail "$CIGO" create --name "$name" --template "$FIXTURES/secret" \
    --image "$CIGO_IT_IMAGE" --check --secret-file "IT_SECRET=$work/absent")
assert_contains "$output" "not a readable regular file" "missing secret file reported"
assert_no_container "$name"
