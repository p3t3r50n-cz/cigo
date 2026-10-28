#!/usr/bin/env bash
# The verbs must not overlap: create refuses an existing container, redeploy
# and configure refuse a missing one, and adoption is an explicit act that
# stamps cigo metadata on a container cigo did not create.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

version=$("$CIGO" --version | awk '{print $2}')
name=$(ct_name verbs)
register_ct "$name"

output=$(cigo_expect_fail "$CIGO" configure --name "$name" --config limits.cpu=1 --yes)
assert_contains "$output" "does not exist" "configure refuses a missing container"
output=$(cigo_expect_fail "$CIGO" redeploy --name "$name" --template "$FIXTURES/basic" --yes)
assert_contains "$output" "does not exist" "redeploy refuses a missing container"

cigo_create "$name" "$FIXTURES/basic" >/dev/null
assert_eq "$version" "$(lxc config get "$name" user.cigo.version)" "version stamped on create"
assert_eq "basic" "$(lxc config get "$name" user.cigo.template)" "template stamped on create"
assert_eq "limits.memory" "$(lxc config get "$name" user.cigo.managed-keys)" \
    "managed keys stamped on create"

output=$(cigo_expect_fail "$CIGO" create --name "$name" --template "$FIXTURES/basic" --yes)
assert_contains "$output" "already exists" "create refuses an existing container"
assert_contains "$output" "redeploy" "create names the verb to use instead"

# Options that only make sense while creating are rejected elsewhere.
output=$(cigo_expect_fail "$CIGO" configure --name "$name" --image ubuntu:22.04 --yes)
assert_contains "$output" "--image applies only to create" "--image rejected by configure"
output=$(cigo_expect_fail "$CIGO" redeploy --name "$name" --template "$FIXTURES/basic" \
    --from other-container --yes)
assert_contains "$output" "--from applies only to create" "--from rejected by redeploy"

# A container created outside cigo is not silently redeployed.
plain=$(ct_name verbs-plain)
register_ct "$plain"
lxc init "$CIGO_IT_IMAGE" "$plain" >/dev/null
output=$(cigo_expect_fail "$CIGO" redeploy --name "$plain" --template "$FIXTURES/basic" --yes)
assert_contains "$output" "not managed by cigo" "redeploy refuses an unmanaged container"
assert_contains "$output" "adopt" "redeploy names adopt as the way in"

output=$(cigo_expect_ok "$CIGO" adopt --name "$plain" --template "$FIXTURES/basic" --yes)
assert_contains "$output" "Container adopted" "adoption reported"
assert_eq "$version" "$(lxc config get "$plain" user.cigo.version)" "version stamped on adopt"
assert_eq "limits.memory" "$(lxc config get "$plain" user.cigo.managed-keys)" \
    "managed keys stamped on adopt"
assert_eq "192MiB" "$(lxc config get "$plain" limits.memory)" "adopt applies declared config"
if [[ -n $(lxc config get "$plain" user.cigo.created-at 2>/dev/null || true) ]]; then
    fail "adopt must not claim a creation time"
fi
pass "adopt does not set created-at"
assert_contains "$(lxc config get "$plain" user.cigo.adopted-at || true)" "T" \
    "adopt records adopted-at"
