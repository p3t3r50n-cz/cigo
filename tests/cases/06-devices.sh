#!/usr/bin/env bash
# Declared devices must be created, reconciled on re-deploy, and the gateway
# built-in must resolve from the LXD network.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./lib.sh

name=$(ct_name device)
register_ct "$name"

work=$(mktemp -d "${TMPDIR:-/tmp}/cigo-it-device.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/one" "$work/two"
printf 'from-one\n' > "$work/one/marker.txt"
printf 'from-two\n' > "$work/two/marker.txt"

cigo_create "$name" "$FIXTURES/device" --var "DATA_DIR=$work/one" >/dev/null

device=$(lxc config device show "$name")
assert_contains "$device" "it-data:" "device created"
assert_contains "$device" "source: $work/one" "device source applied"
assert_eq "from-one" "$(ct_run "$name" "cat /mnt/it-data/marker.txt")" "device is mounted"

gateway=$(ct_run "$name" "sed -n 's/^gateway = //p' /etc/cigo-it/device.conf")
if [[ ! $gateway =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "gateway built-in did not resolve to an address: [$gateway]"
fi
pass "gateway built-in resolved to $gateway"

# Reconcile to a different host directory.
cigo_expect_ok "$CIGO" create --name "$name" --template "$FIXTURES/device" \
    --image "$CIGO_IT_IMAGE" --yes --var "DATA_DIR=$work/two" >/dev/null
device=$(lxc config device show "$name")
assert_contains "$device" "source: $work/two" "device source reconciled"
assert_eq "from-two" "$(ct_run "$name" "cat /mnt/it-data/marker.txt")" \
    "reconciled device is mounted"
