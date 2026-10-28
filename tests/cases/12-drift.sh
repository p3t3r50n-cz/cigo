#!/usr/bin/env bash
# --check on an existing container is a drift report: exit 0 when the
# container matches the declared state, exit 1 when it does not. --dry-run
# prints the same plan but never changes anything.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name drift)
register_ct "$name"

run_status() {
    local status
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    STATUS=$status
}

cigo_create "$name" "$FIXTURES/basic" >/dev/null

output=$(cigo_expect_ok "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --check)
assert_contains "$output" "No drift" "clean container reports no drift"

lxc config set "$name" limits.memory 256MiB

run_status "$CIGO" redeploy --name "$name" --template "$FIXTURES/basic" --check
assert_eq "1" "$STATUS" "drift exit status"
assert_contains "$output" "limits.memory: 256MiB -> 192MiB" "drift change reported"
assert_eq "256MiB" "$(lxc config get "$name" limits.memory)" "--check changed nothing"

run_status "$CIGO" redeploy --name "$name" --template "$FIXTURES/basic" --dry-run
assert_eq "0" "$STATUS" "dry run exit status"
assert_contains "$output" "Dry run complete" "dry run reported"
assert_eq "256MiB" "$(lxc config get "$name" limits.memory)" "--dry-run changed nothing"

# A key set outside cigo is reported, but it is not drift.
lxc config set "$name" boot.stop.priority 3
run_status "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --check
assert_contains "$output" "boot.stop.priority" "unmanaged key reported"
assert_contains "$output" "set outside cigo" "unmanaged key explained"
assert_eq "1" "$STATUS" "drift still comes from the declared key"

cigo_expect_ok "$CIGO" configure --name "$name" --template "$FIXTURES/basic" --yes >/dev/null
output=$(cigo_expect_ok "$CIGO" redeploy --name "$name" --template "$FIXTURES/basic" --check)
assert_contains "$output" "No drift" "drift cleared after configure"
assert_eq "3" "$(lxc config get "$name" boot.stop.priority)" "unmanaged key untouched by apply"
